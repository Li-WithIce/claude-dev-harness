Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProfileRank = [ordered]@{ inspect=0; direct=1; governed=2; critical=3 }

function Assert-ExactKeys {
    param(
        [System.Collections.IDictionary]$Value,
        [string[]]$Expected,
        [string]$Label
    )

    $actual = @($Value.Keys | ForEach-Object { [string]$_ })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $extra = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw ("{0} keys are invalid; missing=[{1}] extra=[{2}]" -f $Label,($missing -join ','),($extra -join ','))
    }
}

function Read-PolicyObject {
    param([string]$Path, [string]$Label)

    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        throw ("{0} is not valid JSON: {1}" -f $Label,$_.Exception.Message)
    }
    if ($value -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object" }
    return $value
}

function Read-ExecutionPolicies {
    param([string]$RepoRoot)

    $execution = Read-PolicyObject -Path (Join-Path $RepoRoot 'policies\execution-profiles.json') -Label 'execution profile policy'
    Assert-ExactKeys -Value $execution -Expected @('profiles','legacy_aliases') -Label 'execution profile policy'
    Assert-ExactKeys -Value $execution.profiles -Expected @('inspect','direct','governed','critical') -Label 'execution profiles'
    Assert-ExactKeys -Value $execution.legacy_aliases -Expected @('quick','workflow','ask_requirement_state') -Label 'legacy aliases'
    if ([string]$execution.legacy_aliases.quick -cne 'direct' -or [string]$execution.legacy_aliases.workflow -cne 'governed' -or [string]$execution.legacy_aliases.ask_requirement_state -cne 'blocked') {
        throw 'legacy aliases are unsafe'
    }
    foreach ($profileName in $script:ProfileRank.Keys) {
        $profile = $execution.profiles[$profileName]
        Assert-ExactKeys -Value $profile -Expected @('allowed_intents','allowed_persistence','minimum_capabilities','configurable_capabilities','writes_task_state','writes_task_artifacts','current_pointer_policy') -Label "execution profile $profileName"
        if ($profile.writes_task_state -isnot [bool] -or $profile.writes_task_artifacts -isnot [bool]) { throw "execution profile write flags are invalid: $profileName" }
    }
    if ($execution.profiles.direct.writes_task_state -ne $false -or $execution.profiles.direct.writes_task_artifacts -ne $false -or @($execution.profiles.direct.minimum_capabilities) -cnotcontains 'verification_required') {
        throw 'direct profile write or verification policy is unsafe'
    }
    $criticalCapabilities = @('plan_required','approval_required','rollback_required','independent_review_required','verification_required','durable_artifacts_required','dry_run_required')
    if (@(Compare-Object $criticalCapabilities @($execution.profiles.critical.minimum_capabilities)).Count -ne 0) { throw 'critical capability policy is unsafe' }

    $risk = Read-PolicyObject -Path (Join-Path $RepoRoot 'policies\risk-rules.json') -Label 'risk policy'
    Assert-ExactKeys -Value $risk -Expected @('dimensions','profile_thresholds','critical_triggers','overrides') -Label 'risk policy'
    Assert-ExactKeys -Value $risk.overrides -Expected @('requirement_blocked_state','read_only_profile','durable_minimum_profile','critical_trigger_profile','multiple_files_alone_escalate') -Label 'risk overrides'
    if ([string]$risk.overrides.requirement_blocked_state -cne 'blocked' -or [string]$risk.overrides.read_only_profile -cne 'inspect' -or [string]$risk.overrides.durable_minimum_profile -cne 'governed' -or [string]$risk.overrides.critical_trigger_profile -cne 'critical' -or $risk.overrides.multiple_files_alone_escalate -ne $false) {
        throw 'risk overrides are unsafe'
    }
    $dimensionIds = @($risk.dimensions | ForEach-Object { [string]$_.id })
    $expectedDimensions = @('user_visible_behavior','data_integrity','authorization_and_security','external_side_effects','blast_radius','rollback','verification_coverage')
    if (@(Compare-Object $expectedDimensions $dimensionIds).Count -ne 0) { throw 'risk dimensions are invalid' }
    foreach ($dimension in $risk.dimensions) {
        Assert-ExactKeys -Value $dimension -Expected @('id','min_score','max_score') -Label 'risk dimension'
        if ([int]$dimension.min_score -ne 0 -or [int]$dimension.max_score -ne 3) { throw "risk dimension bounds are invalid: $($dimension.id)" }
    }
    $thresholds = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($threshold in $risk.profile_thresholds) {
        Assert-ExactKeys -Value $threshold -Expected @('profile','min_total','max_total') -Label 'risk threshold'
        $thresholds[[string]$threshold.profile] = $threshold
    }
    foreach ($profileName in @('direct','governed','critical')) {
        if (-not $thresholds.ContainsKey($profileName)) { throw "risk threshold is missing: $profileName" }
    }
    if ([int]$thresholds.direct.min_total -ne 0 -or [int]$thresholds.direct.max_total -ne 4 -or [int]$thresholds.governed.min_total -ne 5 -or [int]$thresholds.governed.max_total -ne 8 -or [int]$thresholds.critical.min_total -ne 9 -or [int]$thresholds.critical.max_total -ne 21) {
        throw 'risk thresholds are unsafe'
    }
    $expectedCriticalTriggers = @('authorization_or_security_boundary','money_billing_refund_or_settlement','production_database_destructive_migration','irreversible_user_data_change','production_release_or_infrastructure','breaking_public_api_change','sensitive_data_export_or_compliance','destructive_git_history_operation','large_scale_automation_without_dry_run','unverified_production_impact')
    if (@(Compare-Object $expectedCriticalTriggers @($risk.critical_triggers)).Count -ne 0) { throw 'Critical trigger policy is unsafe' }

    $protected = Read-PolicyObject -Path (Join-Path $RepoRoot 'policies\protected-actions.json') -Label 'protected action policy'
    Assert-ExactKeys -Value $protected -Expected @('schema_version','rules') -Label 'protected action policy'
    if ([string]$protected.schema_version -cne 'protected-actions/v1') { throw 'protected action policy version is invalid' }
    $ruleIds = @($protected.rules | ForEach-Object { [string]$_.id })
    if (@(Compare-Object @('production-database-destructive','authorization-path-change') $ruleIds).Count -ne 0) { throw 'protected action rule set is unsafe' }
    foreach ($rule in $protected.rules) {
        Assert-ExactKeys -Value $rule -Expected @('id','match','requires_profile','requires_approval','requires_dry_run','requires_independent_review') -Label 'protected action rule'
        if (-not $script:ProfileRank.Contains([string]$rule.requires_profile) -or $script:ProfileRank[[string]$rule.requires_profile] -lt $script:ProfileRank.governed) { throw "protected rule profile is invalid: $($rule.id)" }
        if ($rule.requires_dry_run -isnot [bool] -or $rule.requires_independent_review -isnot [bool] -or [string]$rule.requires_approval -cnotin @('none','product','architecture','production')) { throw "protected rule requirements are invalid: $($rule.id)" }
        if ($rule.match -isnot [System.Collections.IDictionary]) { throw "protected rule match is invalid: $($rule.id)" }
        $matchKeys = @($rule.match.Keys | ForEach-Object { [string]$_ })
        if ($matchKeys.Count -eq 0 -or @($matchKeys | Where-Object { $_ -cnotin @('command_regex','environment','path_globs') }).Count -gt 0) { throw "protected rule match keys are invalid: $($rule.id)" }
    }

    return [pscustomobject]@{ Execution=$execution; Risk=$risk; Thresholds=$thresholds; Protected=$protected }
}

function Convert-GlobToRegex {
    param([string]$Glob)

    $globText = $Glob.Replace('\','/')
    $builder = [System.Text.StringBuilder]::new('^')
    for ($index = 0; $index -lt $globText.Length; $index++) {
        $character = $globText[$index]
        if ($character -eq '*') {
            $double = $index + 1 -lt $globText.Length -and $globText[$index + 1] -eq '*'
            if ($double) {
                $index++
                if ($index + 1 -lt $globText.Length -and $globText[$index + 1] -eq '/') {
                    $index++
                    [void]$builder.Append('(?:.*/)?')
                } else {
                    [void]$builder.Append('.*')
                }
            } else {
                [void]$builder.Append('[^/]*')
            }
        } elseif ($character -eq '?') {
            [void]$builder.Append('[^/]')
        } else {
            [void]$builder.Append([regex]::Escape([string]$character))
        }
    }
    [void]$builder.Append('$')
    return $builder.ToString()
}

function Get-RaisedProfile {
    param([string]$Current, [string]$Required)
    if ($script:ProfileRank[$Required] -gt $script:ProfileRank[$Current]) { return $Required }
    return $Current
}

function Resolve-HarnessExecutionProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
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
    Assert-ExactKeys -Value $RiskScores -Expected $dimensionIds -Label 'risk scores'
    $riskTotal = 0
    foreach ($dimension in $policies.Risk.dimensions) {
        $score = $RiskScores[[string]$dimension.id]
        if ($score -isnot [byte] -and $score -isnot [sbyte] -and $score -isnot [int16] -and $score -isnot [uint16] -and $score -isnot [int32] -and $score -isnot [uint32] -and $score -isnot [int64] -and $score -isnot [uint64]) {
            throw "risk score must be an integer: $($dimension.id)"
        }
        if ([int]$score -lt [int]$dimension.min_score -or [int]$score -gt [int]$dimension.max_score) { throw "risk score is out of range: $($dimension.id)" }
        $riskTotal += [int]$score
    }

    $knownCritical = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($trigger in $policies.Risk.critical_triggers) { [void]$knownCritical.Add([string]$trigger) }
    foreach ($trigger in $CriticalTriggers) {
        if (-not $knownCritical.Contains($trigger)) { throw "unknown critical trigger: $trigger" }
    }

    $protocol = [System.Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL', [System.EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrWhiteSpace($protocol)) { $protocol = 'auto' }
    if ($protocol -cnotin @('v1','v2','auto')) { throw "HARNESS_PROTOCOL is invalid: $protocol" }
    $selectedProtocol = if ($protocol -ceq 'v2' -and $Identity -ceq 'new') { 'v2' } else { 'v1' }

    $triggers = [System.Collections.Generic.List[string]]::new()
    foreach ($trigger in $CriticalTriggers) { if (-not $triggers.Contains($trigger)) { $triggers.Add($trigger) } }
    if ($RequestedAlias -ceq 'quick') { $triggers.Add('legacy-alias:quick') }
    if ($RequestedAlias -ceq 'workflow') { $triggers.Add('legacy-alias:workflow') }
    if ($RequestedAlias -ceq 'ask') { $triggers.Add('legacy-alias:ask') }

    $blocked = $RequirementState -ceq 'blocked' -or $RequestedAlias -ceq 'ask' -or $ScopeExpanded -or $ProductBlockerDiscovered
    if ($ScopeExpanded) { $triggers.Add('scope-expanded') }
    if ($ProductBlockerDiscovered) { $triggers.Add('product-blocker-discovered') }

    $profile = $null
    $handoff = 'v1-entry'
    $requiredCapabilities = @()
    $artifactPolicy = 'none'
    $reviewPolicy = 'self'
    $approvalPolicy = 'none'

    if ($selectedProtocol -ceq 'v2' -and -not $blocked) {
        if ($Intent -ceq 'read') {
            $profile = 'inspect'
            $handoff = 'read-only-response'
        } else {
            $profile = @($policies.Risk.profile_thresholds | Where-Object { $riskTotal -ge [int]$_.min_total -and $riskTotal -le [int]$_.max_total })[0].profile
            if ($CriticalTriggers.Count -gt 0) { $profile = Get-RaisedProfile -Current $profile -Required ([string]$policies.Risk.overrides.critical_trigger_profile) }
            if ($Persistence -ceq 'durable' -or $DurableArtifactsRequested -or -not $Reversible -or -not $VerificationAvailable -or $RequestedAlias -ceq 'workflow') {
                $profile = Get-RaisedProfile -Current $profile -Required ([string]$policies.Risk.overrides.durable_minimum_profile)
            }
            if ($Persistence -ceq 'durable') { $triggers.Add('durable-persistence') }
            if ($DurableArtifactsRequested) { $triggers.Add('durable-artifacts-requested') }
            if (-not $Reversible) { $triggers.Add('not-readily-reversible') }
            if (-not $VerificationAvailable) { $triggers.Add('verification-unavailable') }

            foreach ($rule in $policies.Protected.rules) {
                $matches = $true
                if ($rule.match.Contains('command_regex')) { $matches = $matches -and $CommandText -match [string]$rule.match.command_regex }
                if ($rule.match.Contains('environment')) { $matches = $matches -and $Environment -ceq [string]$rule.match.environment }
                if ($rule.match.Contains('path_globs')) {
                    $pathMatch = $false
                    foreach ($path in $ChangedPaths) {
                        $normalizedPath = $path.Replace('\','/').TrimStart('/')
                        foreach ($glob in $rule.match.path_globs) {
                            if ($normalizedPath -match (Convert-GlobToRegex -Glob ([string]$glob))) { $pathMatch = $true; break }
                        }
                        if ($pathMatch) { break }
                    }
                    $matches = $matches -and $pathMatch
                }
                if (-not $matches) { continue }

                $triggers.Add("protected:$($rule.id)")
                $profile = Get-RaisedProfile -Current $profile -Required ([string]$rule.requires_profile)
                if ($rule.requires_independent_review -eq $true) { $reviewPolicy = 'independent' }
                if ([string]$rule.requires_approval -cne 'none') { $approvalPolicy = [string]$rule.requires_approval }
                if ($rule.requires_dry_run -eq $true) { $triggers.Add('dry-run-required') }
            }
            $handoff = if ($profile -ceq 'direct') { 'main-agent' } else { 'reroute-before-write' }
        }
        $profilePolicy = $policies.Execution.profiles[$profile]
        $requiredCapabilities = @($profilePolicy.minimum_capabilities)
        if ($reviewPolicy -ceq 'independent' -and $requiredCapabilities -cnotcontains 'independent_review_required') { $requiredCapabilities += 'independent_review_required' }
        if ($approvalPolicy -cne 'none' -and $requiredCapabilities -cnotcontains 'approval_required') { $requiredCapabilities += 'approval_required' }
        if ($triggers -ccontains 'dry-run-required' -and $requiredCapabilities -cnotcontains 'dry_run_required') { $requiredCapabilities += 'dry_run_required' }
        $artifactPolicy = if ($profilePolicy.writes_task_artifacts -eq $true) { 'durable' } else { 'ephemeral' }
        if ($requiredCapabilities -ccontains 'independent_review_required') { $reviewPolicy = 'independent' }
    } elseif ($selectedProtocol -ceq 'v2') {
        $handoff = 'requirement-gate'
    }

    $evidenceSummary = if ($handoff -ceq 'main-agent') {
        [ordered]@{
            format='direct-response'
            persisted=$false
            required_sections=@('changes','focused_verification','self_review','remaining_gaps')
            actual_results_only=$true
        }
    } else { $null }

    return [ordered]@{
        identity=$Identity
        intent=$Intent
        requirement_state=$(if($blocked){'blocked'}else{$RequirementState})
        selected_protocol=$selectedProtocol
        profile=$profile
        risk_total=$riskTotal
        triggers=@($triggers)
        required_capabilities=@($requiredCapabilities | Sort-Object -Unique)
        artifact_policy=$artifactPolicy
        review_policy=$reviewPolicy
        approval_policy=$approvalPolicy
        handoff=$handoff
        evidence_summary=$evidenceSummary
        side_effects=[ordered]@{ task_state_writes=0; runtime_writes=0; artifact_writes=0; external_writes=0 }
    }
}

Export-ModuleMember -Function Resolve-HarnessExecutionProfile
