. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

function Invoke-RequirementInspection {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$RequestFile)

    $RepoRoot,$WorkspaceRoot = (Resolve-Path -LiteralPath $RepoRoot).Path,(Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $request = (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $RequestFile -Label 'RequestFile' -RepoRoot $RepoRoot -Schema requirement-inspection.schema.json -SchemaLabel 'request envelope').Document
    $policy = Read-HarnessKernelJsonPath -Path (Join-Path $RepoRoot 'policies\decision-rights.json') -Label 'decision-rights policy'
    Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $policy -Schema decision-rights.schema.json -Label 'decision-rights policy'

    $owners = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($owner in @('product','architecture','agent')) {
        foreach ($category in @($policy.categories[$owner])) {
            if (-not $owners.TryAdd([string]$category,$owner)) { throw "decision category has multiple owners: $category" }
        }
    }
    $decisionByKey = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($decision in @($request.decisions)) {
        if (-not $decisionByKey.TryAdd([string]$decision.key,$decision)) { throw "duplicate decision key: $($decision.key)" }
        if ($owners[[string]$decision.category] -ceq 'agent' -and -not $decision.Contains('agent_constraints')) { throw "agent decision requires explicit constraints: $($decision.key)" }
    }
    foreach ($decision in @($request.decisions)) {
        foreach ($dependency in @($decision.depends_on)) {
            if ([string]$dependency -ceq [string]$decision.key -or -not $decisionByKey.ContainsKey([string]$dependency)) { throw "decision dependency is missing or self-referential: $($decision.key) -> $dependency" }
        }
    }
    $pending = [Collections.Generic.HashSet[string]]::new($decisionByKey.Keys,[StringComparer]::Ordinal)
    while ($pending.Count) {
        $ready = @($pending | Where-Object {
            $key=$_
            -not @($decisionByKey[$key].depends_on | Where-Object { $pending.Contains([string]$_) }).Count
        })
        if (-not $ready.Count) { throw "decision dependency cycle detected at $(@($pending | Sort-Object)[0])" }
        foreach ($key in $ready) { [void]$pending.Remove($key) }
    }

    $repoEvidence = @(foreach ($check in $(if ($request.Contains('repo_checks')) { @($request.repo_checks) } else { @() })) {
        $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$check.path) -Label "repo_check $($check.id)" -MustExist File
        $text,$digest = (Get-Content -LiteralPath $path -Raw -Encoding utf8),(Get-HarnessFileSha256 -Path $path)
        $status = if ((-not $check.Contains('contains') -or $text.Contains([string]$check.contains,[StringComparison]::Ordinal)) -and (-not $check.Contains('sha256') -or $digest -ceq [string]$check.sha256)) { 'matched' } else { 'repo-evidence-gap' }
        [ordered]@{id=[string]$check.id;path=[string]$check.path;status=$status;digest=$digest}
    })

    $blockers,$productDecisions,$analysis = [Collections.Generic.List[object]]::new(),[Collections.Generic.List[object]]::new(),[ordered]@{}
    foreach ($name in @('product','architecture','agent','conflicts')) {
        $analysis[$name] = [Collections.Generic.List[object]]::new()
    }
    $authorityRank = $policy.authority_rank
    foreach ($decision in @($request.decisions | Sort-Object { [string]$_.key })) {
        $key,$category = [string]$decision.key,[string]$decision.category
        $knownCategory = $owners.ContainsKey($category)
        $owner,$sources = $(if ($knownCategory) { [string]$owners[$category] } else { 'product' }),@($decision.sources | Sort-Object { $authorityRank[[string]$_.authority] }, { [string]$_.source_id })
        $reason,$blockerSources = $null,@()

        if (-not $knownCategory) {
            $reason = 'unknown-decision-category'
        } elseif ($owner -ceq 'agent') {
            if (@($decision.agent_constraints.Values | Where-Object { $_ -ne $true }).Count) {
                $owner,$reason = 'product','agent-constraint-failed'
            } else {
                $analysis.agent.Add([ordered]@{key=$key;category=$category;value=$(if ($sources.Count) { $sources[0].value } else { $decision.recommended });resolution='agent-owned-reversible'})
                continue
            }
        } elseif (-not $sources.Count) {
            $reason = 'unresolved-decision'
        } else {
            $topRank = $authorityRank[[string]$sources[0].authority]
            $topSources = @($sources | Where-Object { $authorityRank[[string]$_.authority] -eq $topRank })
            if (@($topSources | ForEach-Object { ConvertTo-HarnessKernelJson -Value $_.value -Compress } | Sort-Object -CaseSensitive -Unique).Count -gt 1) {
                $blockerSources,$reason = @($topSources | ForEach-Object { Select-HarnessKernelKeys -Value $_ -Keys @('authority','source_id','value') }),'peer-authority-conflict'
                $analysis.conflicts.Add([ordered]@{key=$key;type='peer-authority-conflict';sources=$blockerSources})
            } elseif ($topRank -gt $(if ($owner -ceq 'product') { 2 } else { 3 })) {
                $blockerSources,$reason = @(Select-HarnessKernelKeys -Value $topSources[0] -Keys @('authority','source_id','value')),'insufficient-authority'
            } else {
                $winner = $topSources[0]
                $superseded = @($sources | Where-Object { $authorityRank[[string]$_.authority] -gt $topRank -and (ConvertTo-HarnessKernelJson -Value $_.value -Compress) -cne (ConvertTo-HarnessKernelJson -Value $winner.value -Compress) })
                if ($superseded.Count) {
                    $analysis.conflicts.Add([ordered]@{key=$key;type='current-vs-legacy';winner=(Select-HarnessKernelKeys -Value $winner -Keys @('authority','source_id','value'));superseded=@($superseded | ForEach-Object { Select-HarnessKernelKeys -Value $_ -Keys @('authority','source_id','value') })})
                }
                $analysis[$owner].Add([ordered]@{key=$key;category=$category;value=$winner.value;authority=[string]$winner.authority;source_id=[string]$winner.source_id})
                if ($owner -ceq 'product') { $productDecisions.Add([ordered]@{key=$key;value=$winner.value;source=("{0}:{1}" -f $winner.authority,$winner.source_id)}) }
                continue
            }
        }
        $blockers.Add([ordered]@{key=$key;category=$category;owner=$owner;reason=$reason;sources=$blockerSources})
    }

    $deferred = [Collections.Generic.List[string]]::new()
    $eligible = @(foreach ($blocker in @($blockers | Sort-Object { [string]$_.key })) {
        $decision = $decisionByKey[[string]$blocker.key]
        if (@($decision.depends_on | Where-Object { @($blockers.key) -ccontains [string]$_ }).Count) {
            $deferred.Add([string]$blocker.key)
            continue
        }
        $question = Select-HarnessKernelKeys -Value $decision -Keys @('key','question','impact')
        $question.Insert(1,'owner',[string]$blocker.owner)
        $question.options,$question.recommended = [object[]]$(if($decision.Contains('options')){@($decision.options)}else{@()}),$decision.recommended
        $question.recommendation_is_authorization,$question.depends_on = $false,@($decision.depends_on)
        $question
    })
    $askStyle = if ($request.Contains('ask') -and $request.ask.Contains('style')) { [string]$request.ask.style } else { 'dependency-aware' }
    $askMax = if ($askStyle -ceq 'sequential') { 1 } elseif ($request.Contains('ask') -and $request.ask.Contains('max_independent_questions_per_turn')) { [int]$request.ask.max_independent_questions_per_turn } else { 5 }
    foreach ($remaining in @($eligible | Select-Object -Skip $askMax)) { $deferred.Add([string]$remaining.key) }

    $contractBody = Select-HarnessKernelKeys -Value $request -Keys @('task_id','goal','acceptance','in_scope')
    $contractBody.Insert(0,'schema_version','requirement-contract/v1')
    $contractBody.out_of_scope,$contractBody.product_constraints = [object[]]$(if($request.Contains('out_of_scope')){@($request.out_of_scope)}else{@()}),[object[]]$(if($request.Contains('product_constraints')){@($request.product_constraints)}else{@()})
    $contractBody.product_decisions,$contractBody.unresolved_product_decisions = @($productDecisions | Sort-Object { [string]$_.key }),@()
    $contractBody.source_authority = @($request.source_authority | Sort-Object -Unique)
    $state,$contract = $(if ($blockers.Count) { 'blocked' } else { 'clear' }),$null
    if ($state -ceq 'clear') {
        $contract = Select-HarnessKernelKeys -Value $contractBody -Keys @($contractBody.Keys)
        $contract.digest = Get-HarnessUtf8TextSha256 -Text ($contractBody | ConvertTo-Json -Depth 30 -Compress)
        Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $contract -Schema requirement-contract.schema.json -Label 'derived Requirement Contract' -Depth 30
    }

    return [ordered]@{command='inspect'
        analysis_profile='inspect'
        requirement_state=$state
        confirmed_requirement=(Select-HarnessKernelKeys -Value $contractBody -Keys @('task_id','goal','acceptance','in_scope','out_of_scope','product_constraints','source_authority'))
        contract=$contract
        blocking_decisions=@($blockers)
        ask_batch=$(if($state -ceq 'blocked'){[ordered]@{style=$askStyle;questions=@($eligible|Select-Object -First $askMax);deferred=@($deferred|Sort-Object);statement='Implementation remains blocked until these decisions are explicitly resolved.'}}else{$null})
        decision_analysis=[ordered]@{product=@($analysis.product);architecture=@($analysis.architecture);agent=@($analysis.agent);conflicts=@($analysis.conflicts)}
        repo_evidence=@($repoEvidence)
        side_effects=New-HarnessZeroSideEffects}
}

Export-ModuleMember -Function Invoke-RequirementInspection
