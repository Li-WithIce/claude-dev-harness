Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop

function Read-HarnessGovernanceText {
    param([string]$WorkspaceRoot,[string]$Path,[string]$Label)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $Label -MustExist File
    try { return [System.IO.File]::ReadAllText($fullPath,[System.Text.UTF8Encoding]::new($false,$true)) }
    catch { throw "$Label is not valid UTF-8: $($_.Exception.Message)" }
}

function Get-HarnessGovernanceHeader {
    param([string]$Text,[string]$Name,[string]$Label)
    $matches = [regex]::Matches($Text,"(?m)^- $([regex]::Escape($Name)):\s*(?<value>.+?)\s*$")
    if ($matches.Count -ne 1) { throw "$Label must contain exactly one $Name binding" }
    return $matches[0].Groups['value'].Value.Trim()
}

function Get-HarnessMarkdownSection {
    param([string]$Text,[string]$Name,[string]$Label)
    $pattern = "(?ms)^## $([regex]::Escape($Name))\s*\r?\n(?<body>.*?)(?=^## |\z)"
    $matches = [regex]::Matches($Text,$pattern)
    if ($matches.Count -ne 1) { throw "$Label must contain exactly one $Name section" }
    $body = $matches[0].Groups['body'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($body)) { throw "$Label $Name section is empty" }
    return $body
}

function New-HarnessPlanArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$ContractDigest)
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $path = "docs/tasks/$TaskId/plan.md"
    $target = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'governed plan' -AllowMissing
    if (Test-Path -LiteralPath $target) { throw "governed plan already exists: $path" }
    $templatePath = Join-Path $RepoRoot 'templates\v2\plan.md.template'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw 'governed plan template is unavailable' }
    $content = [System.IO.File]::ReadAllText($templatePath,[System.Text.UTF8Encoding]::new($false,$true)).Replace('{{TASK_ID}}',$TaskId).Replace('{{CONTRACT_DIGEST}}',$ContractDigest)
    return [pscustomobject]@{Path=$path;Content=$content;Digest=(Get-HarnessSha256Text -Content $content)}
}

function Assert-HarnessPlanArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$ContractDigest)
    $path = "docs/tasks/$TaskId/plan.md"
    $text = Read-HarnessGovernanceText -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'governed plan'
    if ((Get-HarnessGovernanceHeader -Text $text -Name 'task_id' -Label 'governed plan') -cne $TaskId) { throw 'governed plan task_id is stale' }
    if ((Get-HarnessGovernanceHeader -Text $text -Name 'contract_digest' -Label 'governed plan') -cne $ContractDigest) { throw 'governed plan contract_digest is stale' }
    if ($text -cmatch '<fill-[a-z0-9-]+>') { throw 'governed plan still contains fill placeholders' }
    foreach ($section in @('Goal','Scope','Implementation','Verification','Rollback')) { [void](Get-HarnessMarkdownSection -Text $text -Name $section -Label 'governed plan') }
    return [pscustomobject]@{Path=$path;Digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path)}
}

function Resolve-HarnessAuditArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$TaskVersion,[Parameter(Mandatory)][string]$ContractDigest,[Parameter(Mandatory)][object]$Evidence,
        [ValidateSet('isolated-context','different-actor')][string]$RequiredIndependence='isolated-context'
    )
    $path = "docs/tasks/$TaskId/audit.md"
    $text = Read-HarnessGovernanceText -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'independent audit'
    if ((Get-HarnessGovernanceHeader -Text $text -Name 'task_id' -Label 'independent audit') -cne $TaskId) { throw 'independent audit task_id is stale' }
    if ((Get-HarnessGovernanceHeader -Text $text -Name 'task_version' -Label 'independent audit') -cne [string]$TaskVersion) { throw 'independent audit task_version is stale' }
    if ((Get-HarnessGovernanceHeader -Text $text -Name 'contract_digest' -Label 'independent audit') -cne $ContractDigest) { throw 'independent audit contract_digest is stale' }
    if ((Get-HarnessGovernanceHeader -Text $text -Name 'verdict' -Label 'independent audit') -cne 'pass') { throw 'independent audit verdict must be pass' }
    if ((Get-HarnessGovernanceHeader -Text $text -Name 'reviewer_participated' -Label 'independent audit') -cne 'false') { throw 'independent reviewer participated in implementation' }

    $recordMatches = [regex]::Matches($text,'(?ms)^<!-- harness-audit-record:start -->\s*\r?\n(?<json>.*?)\r?\n<!-- harness-audit-record:end -->\s*$')
    if ($recordMatches.Count -ne 1) { throw 'independent audit must contain exactly one machine record' }
    try { $record = $recordMatches[0].Groups['json'].Value | ConvertFrom-HarnessJson -ErrorAction Stop }
    catch { throw "independent audit record is not valid JSON: $($_.Exception.Message)" }
    try { $valid = Test-Json -Json ($record | ConvertTo-Json -Depth 20 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\audit-record.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "independent audit record schema validation failed: $($_.Exception.Message)" }
    if (-not $valid) { throw 'independent audit record failed schema validation' }
    if ([string]$record.evidence_digest -cne [string]$Evidence.Digest) { throw 'independent audit evidence_digest is stale' }
    if ($RequiredIndependence -ceq 'different-actor' -and [string]$record.independence_level -cne 'different-actor') { throw 'Critical task requires a different-actor audit' }

    $actors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $contexts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($evidenceRecord in @($Evidence.Document.records)) {
        if (-not $evidenceRecord.Contains('actor') -or $evidenceRecord.actor -isnot [System.Collections.IDictionary] -or -not $evidenceRecord.actor.Contains('actor_id') -or -not $evidenceRecord.actor.Contains('context_id') -or [string]::IsNullOrWhiteSpace([string]$evidenceRecord.actor.actor_id) -or [string]::IsNullOrWhiteSpace([string]$evidenceRecord.actor.context_id)) { throw 'independent audit requires actor_id and context_id on every Evidence record' }
        [void]$actors.Add([string]$evidenceRecord.actor.actor_id);[void]$contexts.Add([string]$evidenceRecord.actor.context_id)
    }
    if ($actors.Count -ne 1 -or $contexts.Count -ne 1) { throw 'independent audit requires one implementer actor and context in Evidence' }
    $implementerActor = @($actors)[0];$implementerContext = @($contexts)[0]
    if ($RequiredIndependence -ceq 'different-actor' -and $Evidence.Document.Contains('dry_run')) {
        $dryRun = $Evidence.Document.dry_run;$dryRunActor = $dryRun.actor
        if ([string]::IsNullOrWhiteSpace([string]$dryRun.command)) { throw 'Critical dry-run command must not be blank' }
        foreach ($field in @('host','model','actor_id','context_id')) { if ([string]::IsNullOrWhiteSpace([string]$dryRunActor[$field])) { throw "Critical dry-run executor $field must not be blank" } }
        if ($dryRunActor.Contains('backend') -and [string]::IsNullOrWhiteSpace([string]$dryRunActor.backend)) { throw 'Critical dry-run executor backend must not be blank' }
        if ([string]$dryRunActor.actor_id -ceq $implementerActor) { throw 'Critical dry-run executor actor must differ from the implementer actor' }
        if ([string]$dryRunActor.context_id -ceq $implementerContext) { throw 'Critical dry-run executor context must differ from the implementer context' }
    }
    if ([string]$record.implementer_actor_id -cne $implementerActor) { throw 'independent audit implementer_actor_id does not match Evidence' }
    if ([string]$record.reviewer_context_id -ceq $implementerContext) { throw 'independent reviewer context must differ from implementer context' }
    if ([string]$record.independence_level -ceq 'different-actor' -and [string]$record.reviewer_actor_id -ceq $implementerActor) { throw 'different-actor audit requires a different reviewer actor' }

    $findings = Get-HarnessMarkdownSection -Text $text -Name 'Findings' -Label 'independent audit'
    if ($findings -cne '- none') {
        foreach ($line in @($findings -split "\r?\n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $finding = [regex]::Match($line,'^- (?<severity>P[0-3]):\s*.+?\s*\|\s*evidence_path=(?<path>[^|]+?)\s*\|\s*evidence_digest=(?<digest>sha256:[0-9a-f]{64})\s*$')
            if (-not $finding.Success) { throw 'independent audit finding must contain structured file evidence' }
            if ($finding.Groups['severity'].Value -cin @('P0','P1')) { throw 'independent audit pass cannot contain a blocking finding' }
            $evidencePath = $finding.Groups['path'].Value.Trim();$expectedDigest = $finding.Groups['digest'].Value
            [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $evidencePath -Label 'audit finding evidence' -MustExist File)
            if ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $evidencePath) -cne $expectedDigest) { throw 'independent audit finding evidence digest mismatch' }
        }
    }
    [void](Get-HarnessMarkdownSection -Text $text -Name 'Evidence' -Label 'independent audit')
    return [pscustomobject]@{Path=$path;Digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path);Record=$record}
}

function Assert-HarnessGovernanceReady {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Task,[Parameter(Mandatory)][object]$Evidence)
    $plan = $null;$audit = $null;$protectedOperation=$null
    $dryRunRequired = if ($Task.policies.Contains('dry_run_required')) { [bool]$Task.policies.dry_run_required } else { [string]$Task.execution_profile -ceq 'critical' }
    if ($dryRunRequired -and [string]$Evidence.NextStatus -ceq 'done') {
        if (-not $Evidence.Document.Contains('dry_run') -or [int]$Evidence.Document.dry_run.exit_code -ne 0) { throw 'dry-run Evidence is required before Critical task completion' }
        if($null-eq$Evidence.ProtectedOperation){throw 'protected_operation is required before Critical task completion'}
        $protectedOperation=$Evidence.ProtectedOperation;$identity=[string]$protectedOperation.identity;$dryRun=$Evidence.Document.dry_run
        if([string]$protectedOperation.approval_type-ceq'none'){throw 'Critical protected_operation requires an Approval type'}
        if(-not$dryRun.Contains('operation_identity')-or[string]$dryRun.operation_identity-cne$identity){throw 'Critical dry-run is not bound to protected_operation'}
        if(@($dryRun.covers).Count-eq0-or@($dryRun.covers)-cnotcontains$identity){throw 'Critical dry-run covers must include protected_operation identity'}
        $executionRecords=@($Evidence.Document.records|Where-Object{[string]$_.type-ceq'command'-and[int]$_.exit_code-eq0-and$_.Contains('operation_identity')-and[string]$_.operation_identity-ceq$identity-and@($_.covers)-ccontains$identity})
        if($executionRecords.Count-eq0){throw 'Critical completion requires successful execution Evidence bound to protected_operation'}
    }
    if ([bool]$Task.policies.plan_required) { $plan = Assert-HarnessPlanArtifact -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Task.task_id) -ContractDigest ([string]$Task.contract_digest) }
    if ([bool]$Task.policies.independent_review_required) {
        $requiredIndependence=if([string]$Task.execution_profile-ceq'critical'){'different-actor'}else{'isolated-context'}
        $audit = Resolve-HarnessAuditArtifact -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Task.task_id) -TaskVersion ([int]$Task.version) -ContractDigest ([string]$Task.contract_digest) -Evidence $Evidence -RequiredIndependence $requiredIndependence
    }
    return [pscustomobject]@{Plan=$plan;Audit=$audit;ProtectedOperation=$protectedOperation}
}

Export-ModuleMember -Function New-HarnessPlanArtifact,Assert-HarnessPlanArtifact,Resolve-HarnessAuditArtifact,Assert-HarnessGovernanceReady
