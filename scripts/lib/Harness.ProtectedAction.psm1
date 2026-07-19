Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Approval.psm1') -Force -ErrorAction Stop

function Assert-HarnessProtectedExactKeys {
    param([System.Collections.IDictionary]$Value,[string[]]$Expected,[string]$Label)
    $actual=@($Value.Keys|ForEach-Object{[string]$_})
    if (@($Expected|Where-Object{$actual-cnotcontains$_}).Count -or @($actual|Where-Object{$Expected-cnotcontains$_}).Count) { throw "$Label keys are invalid" }
}

function Convert-HarnessProtectedGlob {
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

function Assert-HarnessProtectedRule {
    param([System.Collections.IDictionary]$Rule,[string]$Label)
    Assert-HarnessProtectedExactKeys -Value $Rule -Expected @('id','match','requires_profile','requires_approval','requires_dry_run','requires_independent_review') -Label $Label
    if ([string]$Rule.id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "$Label id is invalid" }
    if ($Rule.match -isnot [System.Collections.IDictionary]) { throw "$Label match is invalid" }
    $matchKeys = @($Rule.match.Keys | ForEach-Object { [string]$_ })
    if ($matchKeys.Count -eq 0 -or @($matchKeys | Where-Object { $_ -cnotin @('command_regex','environment','path_globs') }).Count -gt 0) { throw "$Label match keys are invalid" }
    if ($Rule.match.Contains('command_regex')) { try { [void][regex]::new([string]$Rule.match.command_regex) } catch { throw "$Label command_regex is invalid" } }
    if ($Rule.match.Contains('environment') -and [string]::IsNullOrWhiteSpace([string]$Rule.match.environment)) { throw "$Label environment is invalid" }
    if ($Rule.match.Contains('path_globs')) {
        $globs = @($Rule.match.path_globs)
        if ($globs.Count -eq 0 -or @($globs | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -or @($globs | Sort-Object -Unique).Count -ne $globs.Count) { throw "$Label path_globs are invalid" }
    }
    if ([string]$Rule.requires_profile -cnotin @('governed','critical') -or [string]$Rule.requires_approval -cnotin @('none','product','architecture','production') -or $Rule.requires_dry_run -isnot [bool] -or $Rule.requires_independent_review -isnot [bool]) { throw "$Label requirements are invalid" }
}

function Read-HarnessProtectedPolicy {
    param([string]$RepoRoot,[string]$WorkspaceRoot)
    $path=Join-Path $RepoRoot 'policies\protected-actions.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'protected action policy is unavailable'}
    try{$policy=Get-Content -LiteralPath $path -Raw -Encoding utf8|ConvertFrom-HarnessJson -ErrorAction Stop}catch{throw "protected action policy is invalid: $($_.Exception.Message)"}
    Assert-HarnessProtectedExactKeys -Value $policy -Expected @('schema_version','rules') -Label 'protected action policy'
    if([string]$policy.schema_version-cne'protected-actions/v1'){throw 'protected action policy version is invalid'}
    $ids=@($policy.rules|ForEach-Object{[string]$_.id});if(@(Compare-Object @('production-database-destructive','authorization-path-change') $ids).Count){throw 'protected action policy rules are invalid'}
    foreach($rule in @($policy.rules)){
        Assert-HarnessProtectedRule -Rule $rule -Label 'protected action rule'
    }
    $overlayRelative = '.assistant/policies/protected-actions.local.json'
    $overlayPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $overlayRelative -Label 'protected action overlay' -AllowMissing
    if (Test-Path -LiteralPath $overlayPath) {
        if (-not (Test-Path -LiteralPath $overlayPath -PathType Leaf)) { throw 'protected action overlay is invalid: path is not a file' }
        try { $overlayJson = [IO.File]::ReadAllText($overlayPath,[Text.UTF8Encoding]::new($false,$true)); $overlay = $overlayJson | ConvertFrom-HarnessJson -ErrorAction Stop } catch { throw "protected action overlay is invalid: $($_.Exception.Message)" }
        $overlaySchema = Join-Path $RepoRoot 'schemas\protected-actions-overlay.schema.json'
        try { $overlayValid = Test-Json -Json ($overlay | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $overlaySchema -ErrorAction Stop -WarningAction SilentlyContinue } catch { throw "protected action overlay schema is unavailable: $($_.Exception.Message)" }
        if (-not $overlayValid) { throw 'protected action overlay failed schema validation' }
        $knownIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($id in $ids) { [void]$knownIds.Add($id) }
        foreach ($rule in @($overlay.rules)) {
            Assert-HarnessProtectedRule -Rule $rule -Label 'protected action overlay rule'
            if (-not $knownIds.Add([string]$rule.id)) { throw 'protected action overlay rule id collides with another rule' }
            $policy.rules += @($rule)
        }
    }
    return $policy
}

function Read-HarnessProtectedTask {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId)
    Assert-HarnessTaskId -TaskId $TaskId;$path=".assistant/runtime/tasks/$TaskId/task.json";$full=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'protected task' -MustExist File
    try{$task=[IO.File]::ReadAllText($full,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-HarnessJson -ErrorAction Stop}catch{throw "protected task is invalid: $($_.Exception.Message)"}
    try{$valid=Test-Json -Json ($task|ConvertTo-Json -Depth 30 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\task-state.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue}catch{throw "protected task schema is unavailable: $($_.Exception.Message)"}
    if(-not$valid){throw 'protected task failed schema validation'}
    if([string]$task.task_id-cne$TaskId){throw 'protected task task_id does not match its canonical path'}
    $contractPath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$task.contract_path) -Label 'protected task Contract' -MustExist File
    try{$contract=[IO.File]::ReadAllText($contractPath,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-HarnessJson -ErrorAction Stop}catch{throw "protected task Contract is invalid: $($_.Exception.Message)"}
    try{$contractValid=Test-Json -Json ($contract|ConvertTo-Json -Depth 30 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\requirement-contract.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue}catch{throw "protected task Contract schema is unavailable: $($_.Exception.Message)"}
    if(-not$contractValid-or[string]$contract.task_id-cne$TaskId){throw 'protected task Contract failed validation'}
    $canonical=[ordered]@{};foreach($key in @('schema_version','task_id','goal','acceptance','in_scope','out_of_scope','product_constraints','product_decisions','unresolved_product_decisions','source_authority')){if($contract.Contains($key)){$canonical[$key]=$contract[$key]}}
    $actualDigest=Get-HarnessSha256Text -Content ($canonical|ConvertTo-Json -Depth 30 -Compress)
    if([string]$contract.digest-cne$actualDigest-or[string]$task.contract_digest-cne$actualDigest){throw 'protected task Contract digest is stale'}
    return $task
}

function Assert-HarnessProtectedAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [ValidateSet('read-only','write')][string]$SessionMode='write',[ValidateSet('read','write')][string]$ActionMode='read',
        [string]$TaskId='',[Nullable[int]]$ExpectedVersion=$null,[string]$CommandText='',[string[]]$ChangedPaths=@(),[string]$Environment='',[switch]$DryRun,[string]$UserInstruction=''
    )
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if($SessionMode-ceq'read-only'-and$ActionMode-ceq'write'){throw 'read-only session cannot invoke a write tool'}
    if($ActionMode-ceq'read'){return [ordered]@{allowed=$true;protected=$false;matched_rules=@();required_scopes=@();approval_id=$null}}
    $policy=Read-HarnessProtectedPolicy -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    $normalizedPaths=[Collections.Generic.List[string]]::new();foreach($path in $ChangedPaths){$resolved=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'protected action path' -AllowMissing;$normalizedPaths.Add((Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $resolved))}
    $matched=[Collections.Generic.List[object]]::new();$scopes=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($rule in @($policy.rules)){
        $isMatch=$true;$matchingPaths=[Collections.Generic.List[string]]::new()
        if($rule.match.Contains('command_regex')){try{$isMatch=$isMatch-and($CommandText-match[string]$rule.match.command_regex)}catch{throw 'protected command policy regex is invalid'}}
        if($rule.match.Contains('environment')){$isMatch=$isMatch-and($Environment-ceq[string]$rule.match.environment)}
        if($rule.match.Contains('path_globs')){$pathMatch=$false;foreach($path in $normalizedPaths){foreach($glob in @($rule.match.path_globs)){if($path-match(Convert-HarnessProtectedGlob -Glob ([string]$glob))){$pathMatch=$true;$matchingPaths.Add($path);break}}};$isMatch=$isMatch-and$pathMatch}
        if(-not$isMatch){continue};$matched.Add($rule);[void]$scopes.Add("rule:$($rule.id)")
        if($rule.match.Contains('command_regex')){[void]$scopes.Add("command_digest:$((Get-HarnessSha256Text -Content $CommandText))")}
        if($rule.match.Contains('environment')){[void]$scopes.Add("environment:$Environment")}
        foreach($path in $matchingPaths){[void]$scopes.Add("path:$path")}
        if($rule.requires_dry_run-eq$true){[void]$scopes.Add('dry-run:true')}
    }
    if($matched.Count-eq0){return [ordered]@{allowed=$true;protected=$false;matched_rules=@();required_scopes=@();approval_id=$null}}
    $requiredTypes=@($matched|ForEach-Object{[string]$_.requires_approval}|Where-Object{$_-cne'none'}|Sort-Object -Unique)
    if($requiredTypes.Count-gt1){throw 'matched protected rules require conflicting Approval types'}
    $requiredType=$(if($requiredTypes.Count-eq1){[string]$requiredTypes[0]}else{''})
    if([string]::IsNullOrWhiteSpace($TaskId)-or$null-eq$ExpectedVersion){throw 'protected write requires TaskId and ExpectedVersion'}
    $task=Read-HarnessProtectedTask -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    if([int]$task.version-ne[int]$ExpectedVersion){throw "protected task version is stale: expected=$ExpectedVersion actual=$($task.version)"}
    if([string]$task.requirement_state-cne'clear'){throw 'protected write requires a clear Requirement'}
    $rank=@{governed=1;critical=2};$requiredRank=1
    foreach($rule in $matched){$requiredRank=[math]::Max($requiredRank,[int]$rank[[string]$rule.requires_profile]);if($rule.requires_independent_review-eq$true-and-not[bool]$task.policies.independent_review_required){throw 'protected write requires independent review policy'};if($rule.requires_dry_run-eq$true-and-not$DryRun){throw 'protected write requires dry-run'}}
    if(-not$rank.ContainsKey([string]$task.execution_profile)-or[int]$rank[[string]$task.execution_profile]-lt$requiredRank){throw 'protected write task profile is insufficient'}
    $approval=$null;if(-not[string]::IsNullOrWhiteSpace($requiredType)){if(-not[bool]$task.policies.approval_required){throw 'protected write requires approval policy'};$approval=Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task -RequiredType $requiredType -RequiredScopes @($scopes|Sort-Object)}
    return [ordered]@{allowed=$true;protected=$true;matched_rules=@($matched|ForEach-Object{[string]$_.id});required_scopes=@($scopes|Sort-Object);approval_id=$(if($null-ne$approval){[string]$approval.Document.approval_id}else{$null})}
}

Export-ModuleMember -Function Assert-HarnessProtectedAction
