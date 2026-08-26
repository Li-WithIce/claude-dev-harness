Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop

$script:AuthorityRank = [ordered]@{
    'current-user-message' = 0
    'user-confirmed' = 0
    'approved-spec' = 1
    'project-policy' = 2
    'project-product-decision' = 2
    'project-architecture-decision' = 3
    'repo-evidence' = 4
    'engineering-convention' = 5
}

function Assert-KeySet {
    param(
        [System.Collections.IDictionary]$Value,
        [string[]]$Allowed,
        [string[]]$Required,
        [string]$Label
    )

    $unknown = @($Value.Keys | Where-Object { $Allowed -cnotcontains [string]$_ })
    $missing = @($Required | Where-Object { -not $Value.Contains($_) })
    if ($unknown.Count -gt 0 -or $missing.Count -gt 0) {
        throw ("{0} keys are invalid; unknown=[{1}] missing=[{2}]" -f $Label, ($unknown -join ','), ($missing -join ','))
    }
}

function Assert-StringArray {
    param(
        [object]$Value,
        [string]$Label,
        [switch]$NonEmpty
    )

    if ($Value -isnot [System.Collections.IList]) {
        throw "$Label must be an array"
    }
    $items = @($Value)
    if ($NonEmpty -and $items.Count -eq 0) {
        throw "$Label must not be empty"
    }
    if ((@($items | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$_) })).Count -gt 0) {
        throw "$Label must contain only non-empty strings"
    }
    $uniqueItems = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $items) { [void]$uniqueItems.Add([string]$item) }
    if ($uniqueItems.Count -ne $items.Count) {
        throw "$Label must not contain duplicates"
    }
}

function Test-ScalarValue {
    param([object]$Value)

    return $null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]
}

function Get-ScalarToken {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'null:null'
    }
    return ("{0}:{1}" -f $Value.GetType().FullName, ($Value | ConvertTo-Json -Compress))
}

function Resolve-ContainedFile {
    param(
        [string]$Root,
        [string]$Path,
        [string]$Label
    )

    $rootPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $rootPath $Path }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath -cne $rootPath -and -not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes WorkspaceRoot"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }

    $file = Get-Item -LiteralPath $fullPath -Force
    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label crosses a reparse point: $Path"
    }
    $cursor = $file.Directory
    while ($null -ne $cursor -and $cursor.FullName.Length -ge $rootPath.Length) {
        if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label crosses a reparse point: $Path"
        }
        if ($cursor.FullName -ceq $rootPath) {
            break
        }
        $cursor = $cursor.Parent
    }
    return $fullPath
}

function Read-JsonObject {
    param(
        [string]$Path,
        [string]$Label
    )

    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        throw ("{0} is not valid JSON: {1}" -f $Label, $_.Exception.Message)
    }
    if ($value -isnot [System.Collections.IDictionary]) {
        throw "$Label must be a JSON object"
    }
    return $value
}

function Read-DecisionPolicy {
    param([string]$RepoRoot)

    $path = Join-Path $RepoRoot 'policies\decision-rights.json'
    $policy = Read-JsonObject -Path $path -Label 'decision-rights policy'
    Assert-KeySet -Value $policy -Allowed @('schema_version','categories','default_unknown_owner','agent_decision_constraints') -Required @('schema_version','categories','default_unknown_owner','agent_decision_constraints') -Label 'decision-rights policy'
    if ([string]$policy.schema_version -cne 'decision-rights/v1' -or [string]$policy.default_unknown_owner -cne 'product') {
        throw 'decision-rights policy version or default owner is unsafe'
    }
    Assert-KeySet -Value $policy.categories -Allowed @('product','architecture','agent') -Required @('product','architecture','agent') -Label 'decision-rights categories'
    Assert-KeySet -Value $policy.agent_decision_constraints -Allowed @('must_be_reversible','must_not_change_external_behavior','must_follow_repo_conventions','must_be_verified') -Required @('must_be_reversible','must_not_change_external_behavior','must_follow_repo_conventions','must_be_verified') -Label 'agent constraints'

    $owners = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    foreach ($owner in @('product','architecture','agent')) {
        Assert-StringArray -Value $policy.categories[$owner] -Label "decision-rights $owner categories" -NonEmpty
        foreach ($category in @($policy.categories[$owner])) {
            if ($owners.ContainsKey([string]$category)) {
                throw "decision category has multiple owners: $category"
            }
            $owners[[string]$category] = $owner
        }
    }
    foreach ($constraint in $policy.agent_decision_constraints.Keys) {
        if ($policy.agent_decision_constraints[$constraint] -ne $true) {
            throw "agent constraint must fail closed to true: $constraint"
        }
    }
    return [pscustomobject]@{ Document = $policy; Owners = $owners }
}

function Get-FileDigest {
    param([string]$Path)
    return Get-HarnessFileSha256 -Path $Path
}

function Get-ContractDigest {
    param([System.Collections.IDictionary]$ContractWithoutDigest)

    $json = $ContractWithoutDigest | ConvertTo-Json -Depth 30 -Compress
    return Get-HarnessUtf8TextSha256 -Text $json
}

function Assert-RequestEnvelope {
    param(
        [System.Collections.IDictionary]$Request,
        [System.Collections.Generic.Dictionary[string,string]]$Owners
    )

    Assert-KeySet -Value $Request -Allowed @('task_id','goal','acceptance','in_scope','out_of_scope','product_constraints','source_authority','decisions','repo_checks','ask') -Required @('task_id','goal','acceptance','in_scope','source_authority','decisions') -Label 'request envelope'
    if ([string]$Request.task_id -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'request task_id is invalid'
    }
    if ($Request.goal -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Request.goal)) {
        throw 'request goal must be a non-empty string'
    }
    Assert-StringArray -Value $Request.acceptance -Label 'request acceptance' -NonEmpty
    Assert-StringArray -Value $Request.in_scope -Label 'request in_scope' -NonEmpty
    if ($Request.Contains('out_of_scope')) { Assert-StringArray -Value $Request.out_of_scope -Label 'request out_of_scope' }
    if ($Request.Contains('product_constraints')) { Assert-StringArray -Value $Request.product_constraints -Label 'request product_constraints' }
    Assert-StringArray -Value $Request.source_authority -Label 'request source_authority' -NonEmpty
    foreach ($authority in @($Request.source_authority)) {
        if (-not $script:AuthorityRank.Contains([string]$authority)) { throw "unknown source authority: $authority" }
    }
    if ((@($Request.source_authority | Where-Object { $script:AuthorityRank[[string]$_] -le 2 })).Count -eq 0) {
        throw 'request source_authority lacks a product-authoritative source'
    }

    if ($Request.decisions -isnot [System.Collections.IList]) { throw 'request decisions must be an array' }
    $decisions = @($Request.decisions)
    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($decision in $decisions) {
        if ($decision -isnot [System.Collections.IDictionary]) { throw 'each decision must be an object' }
        Assert-KeySet -Value $decision -Allowed @('key','category','question','impact','options','recommended','depends_on','sources','agent_constraints') -Required @('key','category','question','impact','recommended','depends_on','sources') -Label 'decision'
        foreach ($field in @('key','category','question','impact')) {
            if ($decision[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$decision[$field])) { throw "decision $field must be a non-empty string" }
        }
        if (-not $keys.Add([string]$decision.key)) { throw "duplicate decision key: $($decision.key)" }
        if (-not (Test-ScalarValue -Value $decision.recommended)) { throw "decision recommended value must be scalar: $($decision.key)" }
        Assert-StringArray -Value $decision.depends_on -Label "decision $($decision.key) dependencies"
        if ($decision.Contains('options')) { Assert-StringArray -Value $decision.options -Label "decision $($decision.key) options" }
        if ($decision.sources -isnot [System.Collections.IList]) { throw "decision sources must be an array: $($decision.key)" }

        foreach ($source in @($decision.sources)) {
            if ($source -isnot [System.Collections.IDictionary]) { throw "decision source must be an object: $($decision.key)" }
            Assert-KeySet -Value $source -Allowed @('authority','source_id','value') -Required @('authority','source_id','value') -Label "decision $($decision.key) source"
            if (-not $script:AuthorityRank.Contains([string]$source.authority)) { throw "unknown source authority: $($source.authority)" }
            if ($source.source_id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$source.source_id)) { throw 'source_id must be a non-empty string' }
            if (-not (Test-ScalarValue -Value $source.value)) { throw 'decision source value must be scalar' }
        }

        if ($Owners.ContainsKey([string]$decision.category) -and $Owners[[string]$decision.category] -ceq 'agent') {
            if (-not $decision.Contains('agent_constraints') -or $decision.agent_constraints -isnot [System.Collections.IDictionary]) {
                throw "agent decision requires explicit constraints: $($decision.key)"
            }
            Assert-KeySet -Value $decision.agent_constraints -Allowed @('must_be_reversible','must_not_change_external_behavior','must_follow_repo_conventions','must_be_verified') -Required @('must_be_reversible','must_not_change_external_behavior','must_follow_repo_conventions','must_be_verified') -Label "decision $($decision.key) agent constraints"
        }
    }
    foreach ($decision in $decisions) {
        foreach ($dependency in @($decision.depends_on)) {
            if ([string]$dependency -ceq [string]$decision.key -or -not $keys.Contains([string]$dependency)) {
                throw "decision dependency is missing or self-referential: $($decision.key) -> $dependency"
            }
        }
    }

    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $byKey = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($decision in $decisions) { $byKey[[string]$decision.key] = $decision }
    function Visit-Decision([string]$Key) {
        if ($visited.Contains($Key)) { return }
        if (-not $visiting.Add($Key)) { throw "decision dependency cycle detected at $Key" }
        foreach ($dependency in @($byKey[$Key].depends_on)) { Visit-Decision -Key ([string]$dependency) }
        [void]$visiting.Remove($Key); [void]$visited.Add($Key)
    }
    foreach ($key in @($keys)) { Visit-Decision -Key $key }

    if ($Request.Contains('repo_checks')) {
        if ($Request.repo_checks -isnot [System.Collections.IList]) { throw 'request repo_checks must be an array' }
        foreach ($check in @($Request.repo_checks)) {
            if ($check -isnot [System.Collections.IDictionary]) { throw 'each repo_check must be an object' }
            Assert-KeySet -Value $check -Allowed @('id','path','contains','sha256') -Required @('id','path') -Label 'repo_check'
            foreach ($field in @('id','path')) { if ($check[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$check[$field])) { throw "repo_check $field must be non-empty" } }
            if (-not $check.Contains('contains') -and -not $check.Contains('sha256')) { throw "repo_check requires contains or sha256: $($check.id)" }
            if ($check.Contains('contains') -and ($check.contains -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$check.contains))) { throw 'repo_check contains must be non-empty' }
            if ($check.Contains('sha256') -and [string]$check.sha256 -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'repo_check sha256 is invalid' }
        }
    }

    if ($Request.Contains('ask')) {
        Assert-KeySet -Value $Request.ask -Allowed @('style','max_independent_questions_per_turn') -Required @() -Label 'ask config'
        if ($Request.ask.Contains('style') -and [string]$Request.ask.style -cnotin @('dependency-aware','sequential')) { throw 'ask style is invalid' }
        if ($Request.ask.Contains('max_independent_questions_per_turn') -and ([int]$Request.ask.max_independent_questions_per_turn -lt 1 -or [int]$Request.ask.max_independent_questions_per_turn -gt 5)) { throw 'ask batch size must be between 1 and 5' }
    }
}

function Invoke-RequirementInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RequestFile
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $requestPath = Resolve-ContainedFile -Root $WorkspaceRoot -Path $RequestFile -Label 'RequestFile'
    $request = Read-JsonObject -Path $requestPath -Label 'RequestFile'
    $policy = Read-DecisionPolicy -RepoRoot $RepoRoot
    Assert-RequestEnvelope -Request $request -Owners $policy.Owners

    $repoEvidence = [System.Collections.Generic.List[object]]::new()
    $repoChecks = if ($request.Contains('repo_checks')) { @($request.repo_checks) } else { @() }
    foreach ($check in $repoChecks) {
        $path = Resolve-ContainedFile -Root $WorkspaceRoot -Path ([string]$check.path) -Label "repo_check $($check.id)"
        $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
        $digest = Get-FileDigest -Path $path
        $containsMatch = -not $check.Contains('contains') -or $text.Contains([string]$check.contains, [System.StringComparison]::Ordinal)
        $digestMatch = -not $check.Contains('sha256') -or $digest -ceq [string]$check.sha256
        $repoEvidence.Add([ordered]@{ id=[string]$check.id; path=[string]$check.path; status=$(if($containsMatch -and $digestMatch){'matched'}else{'repo-evidence-gap'}); digest=$digest })
    }

    $blockers = [System.Collections.Generic.List[object]]::new()
    $productDecisions = [System.Collections.Generic.List[object]]::new()
    $productAnalysis = [System.Collections.Generic.List[object]]::new()
    $architectureAnalysis = [System.Collections.Generic.List[object]]::new()
    $agentAnalysis = [System.Collections.Generic.List[object]]::new()
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $decisionByKey = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($decision in @($request.decisions)) { $decisionByKey[[string]$decision.key] = $decision }

    foreach ($decision in @($request.decisions | Sort-Object { [string]$_.key })) {
        $key = [string]$decision.key
        $category = [string]$decision.category
        $knownCategory = $policy.Owners.ContainsKey($category)
        $owner = if ($knownCategory) { [string]$policy.Owners[$category] } else { 'product' }
        if (-not $knownCategory) {
            $blockers.Add([ordered]@{ key=$key; category=$category; owner='product'; reason='unknown-decision-category'; sources=@() })
            continue
        }

        $sources = @($decision.sources | Sort-Object { $script:AuthorityRank[[string]$_.authority] }, { [string]$_.source_id })
        if ($owner -ceq 'agent') {
            $constraintsPass = (@($decision.agent_constraints.Values | Where-Object { $_ -ne $true })).Count -eq 0
            if (-not $constraintsPass) {
                $blockers.Add([ordered]@{ key=$key; category=$category; owner='product'; reason='agent-constraint-failed'; sources=@() })
                continue
            }
            $value = if ($sources.Count -gt 0) { $sources[0].value } else { $decision.recommended }
            $agentAnalysis.Add([ordered]@{ key=$key; category=$category; value=$value; resolution='agent-owned-reversible' })
            continue
        }

        if ($sources.Count -eq 0) {
            $blockers.Add([ordered]@{ key=$key; category=$category; owner=$owner; reason='unresolved-decision'; sources=@() })
            continue
        }
        $topRank = $script:AuthorityRank[[string]$sources[0].authority]
        $topSources = @($sources | Where-Object { $script:AuthorityRank[[string]$_.authority] -eq $topRank })
        $topTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($source in $topSources) { [void]$topTokens.Add((Get-ScalarToken -Value $source.value)) }
        if ($topTokens.Count -gt 1) {
            $sourceDetails = @($topSources | ForEach-Object { [ordered]@{ authority=[string]$_.authority; source_id=[string]$_.source_id; value=$_.value } })
            $conflicts.Add([ordered]@{ key=$key; type='peer-authority-conflict'; sources=$sourceDetails })
            $blockers.Add([ordered]@{ key=$key; category=$category; owner=$owner; reason='peer-authority-conflict'; sources=$sourceDetails })
            continue
        }

        $winner = $topSources[0]
        $maxRank = if ($owner -ceq 'product') { 2 } else { 3 }
        if ($topRank -gt $maxRank) {
            $blockers.Add([ordered]@{ key=$key; category=$category; owner=$owner; reason='insufficient-authority'; sources=@([ordered]@{ authority=[string]$winner.authority; source_id=[string]$winner.source_id; value=$winner.value }) })
            continue
        }

        $winnerToken = Get-ScalarToken -Value $winner.value
        $legacyConflict = @($sources | Where-Object { $script:AuthorityRank[[string]$_.authority] -gt $topRank -and (Get-ScalarToken -Value $_.value) -cne $winnerToken })
        if ($legacyConflict.Count -gt 0) {
            $conflicts.Add([ordered]@{ key=$key; type='current-vs-legacy'; winner=[ordered]@{ authority=[string]$winner.authority; source_id=[string]$winner.source_id; value=$winner.value }; superseded=@($legacyConflict | ForEach-Object { [ordered]@{ authority=[string]$_.authority; source_id=[string]$_.source_id; value=$_.value } }) })
        }
        $analysis = [ordered]@{ key=$key; category=$category; value=$winner.value; authority=[string]$winner.authority; source_id=[string]$winner.source_id }
        if ($owner -ceq 'product') {
            $productAnalysis.Add($analysis)
            $productDecisions.Add([ordered]@{ key=$key; value=$winner.value; source=("{0}:{1}" -f $winner.authority,$winner.source_id) })
        } else {
            $architectureAnalysis.Add($analysis)
        }
    }

    $blockingKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($blocker in $blockers) { [void]$blockingKeys.Add([string]$blocker.key) }
    $eligible = [System.Collections.Generic.List[object]]::new()
    $deferred = [System.Collections.Generic.List[string]]::new()
    foreach ($blocker in @($blockers | Sort-Object { [string]$_.key })) {
        $decision = $decisionByKey[[string]$blocker.key]
        $blockedDependency = (@($decision.depends_on | Where-Object { $blockingKeys.Contains([string]$_) })).Count -gt 0
        if ($blockedDependency) {
            $deferred.Add([string]$blocker.key)
        } else {
            [object[]]$options = @()
            if ($decision.Contains('options')) { $options = @($decision.options) }
            $eligible.Add([ordered]@{
                key=[string]$blocker.key
                owner=[string]$blocker.owner
                question=[string]$decision.question
                impact=[string]$decision.impact
                options=$options
                recommended=$decision.recommended
                recommendation_is_authorization=$false
                depends_on=@($decision.depends_on)
            })
        }
    }
    $askStyle = if ($request.Contains('ask') -and $request.ask.Contains('style')) { [string]$request.ask.style } else { 'dependency-aware' }
    $askMax = if ($askStyle -ceq 'sequential') { 1 } elseif ($request.Contains('ask') -and $request.ask.Contains('max_independent_questions_per_turn')) { [int]$request.ask.max_independent_questions_per_turn } else { 5 }
    $questions = @($eligible | Select-Object -First $askMax)
    foreach ($remaining in @($eligible | Select-Object -Skip $askMax)) { $deferred.Add([string]$remaining.key) }

    [object[]]$outOfScope = @()
    [object[]]$productConstraints = @()
    if ($request.Contains('out_of_scope')) { $outOfScope = @($request.out_of_scope) }
    if ($request.Contains('product_constraints')) { $productConstraints = @($request.product_constraints) }
    $confirmedRequirement = [ordered]@{
        task_id=[string]$request.task_id
        goal=[string]$request.goal
        acceptance=@($request.acceptance)
        in_scope=@($request.in_scope)
        out_of_scope=$outOfScope
        product_constraints=$productConstraints
        source_authority=@($request.source_authority | Sort-Object -Unique)
    }
    $contract = $null
    $state = if ($blockers.Count -eq 0) { 'clear' } else { 'blocked' }
    if ($state -ceq 'clear') {
        $withoutDigest = [ordered]@{
            schema_version='requirement-contract/v1'
            task_id=$confirmedRequirement.task_id
            goal=$confirmedRequirement.goal
            acceptance=$confirmedRequirement.acceptance
            in_scope=$confirmedRequirement.in_scope
            out_of_scope=$confirmedRequirement.out_of_scope
            product_constraints=$confirmedRequirement.product_constraints
            product_decisions=@($productDecisions | Sort-Object { [string]$_.key })
            unresolved_product_decisions=@()
            source_authority=$confirmedRequirement.source_authority
        }
        $contract = [ordered]@{}; foreach ($key in $withoutDigest.Keys) { $contract[$key] = $withoutDigest[$key] }
        $contract.digest = Get-ContractDigest -ContractWithoutDigest $withoutDigest
        $schemaPath = Join-Path $RepoRoot 'schemas\requirement-contract.schema.json'
        if (-not (Test-Json -Json ($contract | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) {
            throw 'derived Requirement Contract failed schema validation'
        }
    }

    return [ordered]@{
        command='inspect'
        analysis_profile='inspect'
        requirement_state=$state
        confirmed_requirement=$confirmedRequirement
        contract=$contract
        blocking_decisions=@($blockers)
        ask_batch=$(if($state -ceq 'blocked'){[ordered]@{ style=$askStyle; questions=$questions; deferred=@($deferred | Sort-Object); statement='Implementation remains blocked until these decisions are explicitly resolved.' }}else{$null})
        decision_analysis=[ordered]@{ product=@($productAnalysis); architecture=@($architectureAnalysis); agent=@($agentAnalysis); conflicts=@($conflicts) }
        repo_evidence=@($repoEvidence)
        side_effects=[ordered]@{ task_state_writes=0; runtime_writes=0; artifact_writes=0; external_writes=0 }
    }
}

Export-ModuleMember -Function Invoke-RequirementInspection
