Import-Module (Join-Path $PSScriptRoot 'Harness.Protocol.psm1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

$script:ProfileRank = [ordered]@{ inspect=0; direct=1;
     governed=2; critical=3 }

function Read-ExecutionPolicies {
    param([string]$RepoRoot)
    $policies = [ordered]@{
        execution=Read-HarnessKernelJson -Path (Join-Path $RepoRoot 'policies\execution-profiles.json') -Label 'execution profile policy'
        risk=Read-HarnessKernelJson -Path (Join-Path $RepoRoot 'policies\risk-rules.json') -Label 'risk policy'
        protected=Read-HarnessKernelJson -Path (Join-Path $RepoRoot 'policies\protected-actions.json') -Label 'protected action policy'}
    Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $policies -Schema runtime-policies.schema.json -Label 'Runtime policies'
    foreach ($match in @($policies.protected.rules.match | Where-Object { $_.Contains('command_regex') })) {
        try { [void][regex]::new([string]$match.command_regex) }
        catch { throw 'Runtime policies contain an invalid command regex' }
    }
    return $policies
}

function Resolve-HarnessExecutionProfile {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$WorkspaceRoot = '',
        [ValidateSet('new','existing','resume')][string]$Identity = 'new',
        [ValidateSet('read','write')][string]$Intent = 'write',
        [ValidateSet('clear','blocked')][string]$RequirementState = 'clear',
        [ValidateSet('ephemeral','durable')][string]$Persistence = 'ephemeral',
        [Parameter(Mandatory)][System.Collections.IDictionary]$RiskScores,
        [string[]]$CriticalTriggers = @(),
        [string[]]$ChangedPaths = @(),
        [string]$CommandText = '',
        [string]$Environment = '',
        [ValidateSet('','quick','workflow','ask')][string]$RequestedAlias = '',
        [bool]$Reversible = $true,
        [bool]$VerificationAvailable = $true,
        [bool]$DurableArtifactsRequested = $false,
        [bool]$ScopeExpanded = $false,
        [bool]$ProductBlockerDiscovered = $false
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $policies = Read-ExecutionPolicies -RepoRoot $RepoRoot
    $dimensionIds = @($policies.Risk.dimensions | ForEach-Object { [string]$_.id })
    Assert-HarnessKernelCondition (-not @($RiskScores.Keys | Where-Object { $dimensionIds -cnotcontains $_ }).Count -and $RiskScores.Count -eq $dimensionIds.Count) 'risk scores keys are invalid'
    $riskTotal = 0
    foreach ($dimension in $policies.Risk.dimensions) {
        $score = $RiskScores[[string]$dimension.id]
        Assert-HarnessKernelCondition ($null-ne$score-and$score.GetType()-in$script:HarnessIntegerTypes) "risk score must be an integer: $($dimension.id)"
        if ([int]$score -lt [int]$dimension.min_score -or [int]$score -gt [int]$dimension.max_score) { throw "risk score is out of range: $($dimension.id)" }
        $riskTotal += [int]$score
    }

    foreach($unknownCritical in @($CriticalTriggers|Where-Object{@($policies.Risk.critical_triggers)-cnotcontains$_}|Select-Object -First 1)){throw "unknown critical trigger: $unknownCritical"}

    if ($Identity -ceq 'new') {
        if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = $RepoRoot }
        $protocolResolution = Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -RequestedProtocol ([Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[EnvironmentVariableTarget]::Process))
        if ($protocolResolution.selected_protocol -cne 'v2') { throw "new-work-not-admitted: $($protocolResolution.reason)" }
    }

    $triggers = [System.Collections.Generic.List[string]]::new([string[]]@($CriticalTriggers | Select-Object -Unique))
    if ($RequestedAlias -cin @('quick','workflow','ask')) { $triggers.Add("legacy-alias:$RequestedAlias") }

    $blocked = $RequirementState -ceq 'blocked' -or $RequestedAlias -ceq 'ask' -or $ScopeExpanded -or $ProductBlockerDiscovered
    if ($ScopeExpanded) { $triggers.Add('scope-expanded') }
    if ($ProductBlockerDiscovered) { $triggers.Add('product-blocker-discovered') }

    $profile,$handoff,$requiredCapabilities,$reviewPolicy,$approvalPolicy = $null,'v2-recovery',@(),'self','none'
    $approvalTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    if ($Identity -ceq 'new' -and -not $blocked) {
        if ($Intent -ceq 'read') {
            $profile,$handoff = 'inspect','read-only-response'
        } else {
            $profile = @($policies.Risk.profile_thresholds | Where-Object { $riskTotal -ge [int]$_.min_total -and $riskTotal -le [int]$_.max_total })[0].profile
            if ($CriticalTriggers.Count -gt 0 -and $script:ProfileRank[$policies.Risk.overrides.critical_trigger_profile] -gt $script:ProfileRank[$profile]) { $profile = [string]$policies.Risk.overrides.critical_trigger_profile }
            if ($Persistence -ceq 'durable' -or $DurableArtifactsRequested -or -not $Reversible -or -not $VerificationAvailable -or $RequestedAlias -ceq 'workflow') {
                if ($script:ProfileRank[$policies.Risk.overrides.durable_minimum_profile] -gt $script:ProfileRank[$profile]) { $profile = [string]$policies.Risk.overrides.durable_minimum_profile }
            }
            if ($Persistence -ceq 'durable') { $triggers.Add('durable-persistence') }
            if ($DurableArtifactsRequested) { $triggers.Add('durable-artifacts-requested') }
            if (-not $Reversible) { $triggers.Add('not-readily-reversible') }
            if (-not $VerificationAvailable) { $triggers.Add('verification-unavailable') }

            foreach ($rule in $policies.Protected.rules) {
                if ($null -eq (Resolve-HarnessProtectedRuleMatch -Rule $rule -CommandText $CommandText -Paths $ChangedPaths -Environment $Environment)) { continue }
                $triggers.Add("protected:$($rule.id)")
                if ($script:ProfileRank[$rule.requires_profile] -gt $script:ProfileRank[$profile]) { $profile = [string]$rule.requires_profile }
                if ($rule.requires_independent_review -eq $true) { $reviewPolicy = 'independent' }
                if ([string]$rule.requires_approval -cne 'none') { [void]$approvalTypes.Add([string]$rule.requires_approval) }
                if ($rule.requires_dry_run -eq $true) { $triggers.Add('dry-run-required') }
            }
            if ($approvalTypes.Count -gt 1) { throw 'matched protected rules require conflicting Approval types' }
            if ($approvalTypes.Count -eq 1) { $approvalPolicy = [string](@($approvalTypes)[0]) }
            $handoff = if ($profile -ceq 'direct') { 'main-agent' } else { 'reroute-before-write' }
        }
        $requiredCapabilities = @($policies.Execution.profiles[$profile].minimum_capabilities)
        if ($reviewPolicy -ceq 'independent') { $requiredCapabilities += 'independent_review_required' }
        if ($approvalPolicy -cne 'none') { $requiredCapabilities += 'approval_required' }
        if ($triggers -ccontains 'dry-run-required') { $requiredCapabilities += 'dry_run_required' }
        if ($requiredCapabilities -ccontains 'independent_review_required') { $reviewPolicy = 'independent' }
    } elseif ($blocked) {
        $handoff = 'requirement-gate'
    }

    return [ordered]@{identity=$Identity
        intent=$Intent
        requirement_state=$(if($blocked){'blocked'}else{$RequirementState})
        selected_protocol='v2'
        profile=$profile
        risk_total=$riskTotal
        triggers=@($triggers)
        required_capabilities=@($requiredCapabilities | Sort-Object -Unique)
        artifact_policy=$(if($null-eq$profile){'none'}elseif($policies.Execution.profiles[$profile].writes_task_artifacts-eq$true){'durable'}else{'ephemeral'})
        review_policy=$reviewPolicy
        approval_policy=$approvalPolicy
        handoff=$handoff
        evidence_summary=$(if ($handoff -ceq 'main-agent') {
            [ordered]@{format='direct-response'
                persisted=$false
                required_sections=@('changes','focused_verification','self_review','remaining_gaps')
                actual_results_only=$true}
        } else { $null })
        side_effects=New-HarnessZeroSideEffects}
}

Export-ModuleMember -Function Resolve-HarnessExecutionProfile
