. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

function Invoke-RequirementInspection {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RequestFile
    )

    $RepoRoot,$WorkspaceRoot = (Resolve-Path -LiteralPath $RepoRoot).Path,(Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $request = (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $RequestFile -Label 'RequestFile' -RepoRoot $RepoRoot -Schema requirement-inspection.schema.json -SchemaLabel 'request envelope').Document
    $policy = Read-HarnessKernelJson -Path (Join-Path $RepoRoot 'policies\decision-rights.json') -Label 'decision-rights policy' -RepoRoot $RepoRoot -Schema decision-rights.schema.json

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

    $repoEvidence = @(foreach ($check in @($request['repo_checks'])) {
        $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$check.path) -Label "repo_check $($check.id)" -MustExist File
        $text,$digest = (Get-Content -LiteralPath $path -Raw -Encoding utf8),(Get-HarnessFileSha256 -Path $path)
        [ordered]@{id=[string]$check.id;path=[string]$check.path;
            status=$(if ((-not $check.Contains('contains') -or $text.Contains([string]$check.contains,[StringComparison]::Ordinal)) -and (-not $check.Contains('sha256') -or $digest -ceq [string]$check.sha256)) { 'matched' } else { 'repo-evidence-gap' });digest=$digest}
    })

    $blockers,$productDecisions = [Collections.Generic.List[object]]::new(),[Collections.Generic.List[object]]::new()
    $analysis = [ordered]@{product=[Collections.Generic.List[object]]::new();architecture=[Collections.Generic.List[object]]::new()
        agent=[Collections.Generic.List[object]]::new();conflicts=[Collections.Generic.List[object]]::new()}
    $authorityRank = $policy.authority_rank
    $sourceKeys = @('authority','source_id','value')
    foreach ($decision in @($request.decisions | Sort-Object { [string]$_.key })) {
        $key,$category = [string]$decision.key,[string]$decision.category
        $knownCategory = $owners.ContainsKey($category)
        $owner,$sources = $(if ($knownCategory) { [string]$owners[$category] } else { 'product' }),@($decision.sources | Sort-Object { $authorityRank[[string]$_.authority] }, { [string]$_.source_id })
        $blockerSources = @()
        $reason = if (-not $knownCategory) { 'unknown-decision-category' }
            elseif ($owner -ceq 'agent' -and @($decision.agent_constraints.Values | Where-Object { $_ -ne $true }).Count) {
                $owner = 'product'
                'agent-constraint-failed'
            } elseif ($owner -cne 'agent' -and -not $sources.Count) { 'unresolved-decision' } else { $null }
        if ($owner -ceq 'agent') {
            $analysis.agent.Add([ordered]@{key=$key;category=$category;
                value=$(if ($sources.Count) { $sources[0].value } else { $decision.recommended });resolution='agent-owned-reversible'})
            continue
        }
        if (-not $reason) {
            $topRank = $authorityRank[[string]$sources[0].authority]
            $topSources = @($sources | Where-Object { $authorityRank[[string]$_.authority] -eq $topRank })
            if (@($topSources | Where-Object { -not (Test-HarnessKernelValueEqual -Left $_.value -Right $topSources[0].value) }).Count) {
                $blockerSources,$reason = @($topSources | ForEach-Object { Select-HarnessKernelKeys -Value $_ -Keys $sourceKeys }),'peer-authority-conflict'
                $analysis.conflicts.Add([ordered]@{key=$key;type='peer-authority-conflict';sources=$blockerSources})
            } elseif ($topRank -gt $(if ($owner -ceq 'product') { 2 } else { 3 })) {
                $blockerSources,$reason = @(Select-HarnessKernelKeys -Value $topSources[0] -Keys $sourceKeys),'insufficient-authority'
            } else {
                $winner = $topSources[0]
                $superseded = @($sources | Where-Object { $authorityRank[[string]$_.authority] -gt $topRank -and -not (Test-HarnessKernelValueEqual -Left $_.value -Right $winner.value) })
                if ($superseded.Count) {
                    $analysis.conflicts.Add([ordered]@{key=$key;type='current-vs-legacy';
                        winner=(Select-HarnessKernelKeys -Value $winner -Keys $sourceKeys);superseded=@($superseded | ForEach-Object { Select-HarnessKernelKeys -Value $_ -Keys $sourceKeys })})
                }
                $analysis[$owner].Add([ordered]@{key=$key;category=$category;
                    value=$winner.value;authority=[string]$winner.authority;
                    source_id=[string]$winner.source_id})
                if ($owner -ceq 'product') { $productDecisions.Add([ordered]@{key=$key;value=$winner.value;source=("{0}:{1}" -f $winner.authority,$winner.source_id)}) }
                continue
            }
        }
        $blockers.Add([ordered]@{key=$key;category=$category;
            owner=$owner;reason=$reason;
            sources=$blockerSources})
    }

    $ask = $request['ask']
    $askStyle = if ($null -ne $ask -and $ask['style']) { [string]$ask.style } else { 'dependency-aware' }
    $blockerKeys = [Collections.Generic.HashSet[string]]::new([string[]]@($blockers | ForEach-Object { [string]$_.key }),[StringComparer]::Ordinal)
    $questions = @($(foreach ($blocker in @($blockers | Sort-Object { [string]$_.key })) {
        $decision = $decisionByKey[[string]$blocker.key]
        if (-not @($decision.depends_on | Where-Object { $blockerKeys.Contains([string]$_) }).Count) {
            $question = Select-HarnessKernelKeys -Value $decision -Keys @('key','question','impact')
            $question.Insert(1,'owner',[string]$blocker.owner)
            $question.options,$question.recommended = [object[]]@($decision['options']),$decision.recommended
            $question.recommendation_is_authorization,$question.depends_on = $false,@($decision.depends_on)
            $question
        }
    }) | Select-Object -First $(if ($askStyle -ceq 'sequential') { 1 } elseif ($null -ne $ask -and $ask['max_independent_questions_per_turn']) { [int]$ask.max_independent_questions_per_turn } else { 5 }))

    $contractBody = Select-HarnessKernelKeys -Value $request -Keys @('task_id','goal','acceptance','in_scope')
    $contractBody.Insert(0,'schema_version','requirement-contract/v1')
    $contractBody.out_of_scope,$contractBody.product_constraints = [object[]]@($request['out_of_scope']),[object[]]@($request['product_constraints'])
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
        ask_batch=$(if($state -ceq 'blocked'){[ordered]@{style=$askStyle;questions=$questions;
            deferred=@($blockerKeys | Where-Object { @($questions.key) -cnotcontains $_ } | Sort-Object);statement='Implementation remains blocked until these decisions are explicitly resolved.'}}else{$null})
        decision_analysis=[ordered]@{product=@($analysis.product);architecture=@($analysis.architecture);
            agent=@($analysis.agent);conflicts=@($analysis.conflicts)}
        repo_evidence=@($repoEvidence)
        side_effects=New-HarnessZeroSideEffects}
}

Export-ModuleMember -Function Invoke-RequirementInspection
