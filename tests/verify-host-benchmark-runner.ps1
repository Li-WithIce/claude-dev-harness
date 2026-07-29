[CmdletBinding()]
param([string]$RepoRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$failures=[Collections.Generic.List[string]]::new();$checks=0
function Check([bool]$Condition,[string]$Message){if($Condition){$script:checks++}else{$script:failures.Add($Message)}}
function Get-CompactAstText([AllowNull()][Management.Automation.Language.Ast]$Ast){
    if($null-eq$Ast){return ''}
    return (($Ast.Extent.Text-replace'\s+',' ').Trim())
}
function Get-OwnedAssignmentAst([Management.Automation.Language.FunctionDefinitionAst]$FunctionAst,[string]$Name){
    $result=[Collections.Generic.List[Management.Automation.Language.AssignmentStatementAst]]::new()
    foreach($assignment in @($FunctionAst.Body.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]-and$node.Left-is[Management.Automation.Language.VariableExpressionAst]-and$node.Left.VariablePath.UserPath-ceq$Name},$true))){
        $owner=$assignment.Parent
        while($null-ne$owner-and$owner-isnot[Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
        if([object]::ReferenceEquals($owner,$FunctionAst)){$result.Add($assignment)}
    }
    return @($result)
}
function Test-ExactOwnedAssignment([Management.Automation.Language.FunctionDefinitionAst]$FunctionAst,[string]$Name,[string]$ExpectedRight){
    $assignments=@(Get-OwnedAssignmentAst -FunctionAst $FunctionAst -Name $Name)
    return $assignments.Count-eq1-and$assignments[0].Operator-eq[Management.Automation.Language.TokenKind]::Equals-and(Get-CompactAstText $assignments[0].Right)-ceq$ExpectedRight
}
function Test-V1WriteBoundaryDataflow([string]$TrialText,[string]$RunnerText){
    $trialTokens=$null;$trialErrors=$null;$trialAst=[Management.Automation.Language.Parser]::ParseInput($TrialText,[ref]$trialTokens,[ref]$trialErrors)
    $runnerTokens=$null;$runnerErrors=$null;$runnerAst=[Management.Automation.Language.Parser]::ParseInput($RunnerText,[ref]$runnerTokens,[ref]$runnerErrors)
    if(@($trialErrors).Count-ne0-or@($runnerErrors).Count-ne0){return $false}
    $trialFunctions=@($trialAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Invoke-HostTrial'},$true))
    $runnerFunctions=@($runnerAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Test-HostRunnerTrialEvidence'},$true))
    if($trialFunctions.Count-ne1-or$runnerFunctions.Count-ne1){return $false}
    $trialFunction=$trialFunctions[0];$runnerFunction=$runnerFunctions[0]
    $trialExpected=[ordered]@{
        v1ArtifactAllowlist='@(''docs/tasks/host-benchmark-fixed-workflow/plan.md'',''docs/tasks/host-benchmark-fixed-workflow/test.md'',''docs/tasks/host-benchmark-fixed-workflow/skill-manifest.json'')'
        v1RequiredArtifacts='@(''docs/tasks/host-benchmark-fixed-workflow/plan.md'',''docs/tasks/host-benchmark-fixed-workflow/test.md'')'
        v1RuntimeAllowlist='@(''.assistant/运行时/当前任务.md'',''.assistant/运行时/恢复索引.md'',''.assistant/运行时/tasks/host-benchmark-fixed-workflow.md'')'
        v1AllowedWritePaths='@(''src/value.txt'') + $v1ArtifactAllowlist + $v1RuntimeAllowlist'
        v1AllowedWritePathText='@($v1AllowedWritePaths | ForEach-Object { "''$_''" }) -join '', '''
        writeBoundaryContract='if ($Protocol -ceq ''v1'') { "The only paths this fixed comparator may change are $v1AllowedWritePathText. Do not create or change any other path, including temporary, log, backup, or verification files." } else { "Change no path other than ''src/value.txt''. Do not create task, runtime, artifact, temporary, log, backup, or verification files." }'
        task='@" Work only inside this workspace. The user explicitly authorizes this complete, reversible, private one-file task and all normal harness stage transitions needed to finish it. $routeContext $taskAction Do not ask about scope, acceptance, rollback, or authorization: they are fully confirmed here. $writeBoundaryContract Return only schema-valid JSON. Set task_completed and verification_passed true only after the exact file check required for this turn has actually passed and, for the fixed v1 comparator, its plan stage is DONE. "@'
        unexpectedWrites='@($changed | Where-Object { if ($_ -ceq ''src/value.txt'') { return $false } if ($Protocol -ceq ''v1'' -and $_ -cin $v1AllowedWritePaths) { return $false } return $true }).Count'
    }
    $runnerExpected=[ordered]@{
        artifactAllowlist='@(''docs/tasks/host-benchmark-fixed-workflow/plan.md'',''docs/tasks/host-benchmark-fixed-workflow/test.md'',''docs/tasks/host-benchmark-fixed-workflow/skill-manifest.json'')'
        requiredArtifacts='@(''docs/tasks/host-benchmark-fixed-workflow/plan.md'',''docs/tasks/host-benchmark-fixed-workflow/test.md'')'
        runtimeAllowlist='@(''.assistant/运行时/当前任务.md'',''.assistant/运行时/恢复索引.md'',''.assistant/运行时/tasks/host-benchmark-fixed-workflow.md'')'
        allowed='@(''src/value.txt'') + $artifactAllowlist + $runtimeAllowlist'
    }
    foreach($name in $trialExpected.Keys){if(-not(Test-ExactOwnedAssignment -FunctionAst $trialFunction -Name $name -ExpectedRight $trialExpected[$name])){return $false}}
    foreach($name in $runnerExpected.Keys){if(-not(Test-ExactOwnedAssignment -FunctionAst $runnerFunction -Name $name -ExpectedRight $runnerExpected[$name])){return $false}}
    $trialOrder=@('v1ArtifactAllowlist','v1RequiredArtifacts','v1RuntimeAllowlist','v1AllowedWritePaths','v1AllowedWritePathText','writeBoundaryContract','task','unexpectedWrites')|ForEach-Object{(Get-OwnedAssignmentAst -FunctionAst $trialFunction -Name $_)[0].Extent.StartOffset}
    for($index=1;$index-lt$trialOrder.Count;$index++){if($trialOrder[$index]-le$trialOrder[$index-1]){return $false}}
    $runnerRejection='if (@($changed | Where-Object { $_ -cnotin $allowed }).Count -ne 0 -or @($requiredArtifacts | Where-Object { $_ -cnotin $artifactChanges }).Count -ne 0 -or $artifactChanges.Count -notin @(2,3) -or $runtimeChanges.Count -ne 3) { return $false }'
    $runnerRejectionNodes=@($runnerFunction.Body.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and(Get-CompactAstText $node)-ceq$runnerRejection},$true))
    if($runnerRejectionNodes.Count-ne1){return $false}
    $runnerOrder=@('artifactAllowlist','requiredArtifacts','runtimeAllowlist','allowed')|ForEach-Object{(Get-OwnedAssignmentAst -FunctionAst $runnerFunction -Name $_)[0].Extent.StartOffset}
    $runnerOrder+=@($runnerRejectionNodes[0].Extent.StartOffset)
    for($index=1;$index-lt$runnerOrder.Count;$index++){if($runnerOrder[$index]-le$runnerOrder[$index-1]){return $false}}
    $outer=$runnerRejectionNodes[0].Parent
    while($null-ne$outer-and$outer-isnot[Management.Automation.Language.IfStatementAst]){$outer=$outer.Parent}
    return $null-ne$outer-and$outer.Clauses.Count-eq2-and$null-eq$outer.ElseClause-and
        (Get-CompactAstText $outer.Clauses[0].Item1)-ceq"`$Protocol -ceq 'v1'"-and
        (Get-CompactAstText $outer.Clauses[1].Item1)-ceq'$changed.Count -ne 1 -or $artifactChanges.Count -ne 0 -or $runtimeChanges.Count -ne 0'
}
function Get-ExactCommandAst {
    param([AllowNull()][Management.Automation.Language.Ast]$Ast,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Ast) { return @() }
    return @($Ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | Where-Object { $_.GetCommandName() -ceq $Name })
}
function Get-UnsupportedHostSchemaKeyword {
    param([AllowNull()]$Value)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ([string]$key -cin @('allOf','oneOf','not','dependentRequired','dependentSchemas','if','then','else','const')) { [string]$key }
            Get-UnsupportedHostSchemaKeyword -Value $Value[$key]
        }
    } elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Get-UnsupportedHostSchemaKeyword -Value $item }
    }
}
$runner=Join-Path $RepoRoot 'scripts\run-host-benchmark.ps1'
$schema=Join-Path $RepoRoot 'schemas\host-benchmark\observation.schema.json'
$wrapper=Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
$atomic=Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1'
$pathModule=Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1'
$otel=Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Otel.ps1'
$trial=Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1'
$collector=Join-Path $RepoRoot 'scripts\receive-otlp-http.ps1'
foreach($path in @($runner,$schema,$wrapper,$atomic,$pathModule,$otel,$trial,$collector)){Check (Test-Path -LiteralPath $path -PathType Leaf) "missing host benchmark contract: $path"}
Check (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'scripts\lib\HostBenchmark.Common.ps1'))) 'quarantined Common helper still exists'
Check (@(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts\lib') -Filter 'HostBenchmark.*' -File -ErrorAction Stop).Count -eq 0) 'release-only host benchmark helper leaked into the core runtime library'
foreach($path in @($runner,$atomic,$pathModule,$otel,$trial,$collector,$PSCommandPath)){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "PowerShell parse failed: $path"}
$schemaDocument=[IO.File]::ReadAllText($schema,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json -AsHashtable -Depth 20
$unsupportedSchemaKeywords=@(Get-UnsupportedHostSchemaKeyword -Value $schemaDocument)
$schemaFields=@('schema_version','outcome','task_completed','verification_executed','verification_passed','reason_code')
$schemaRootValid=@($schemaDocument.Keys).Count-eq4-and$schemaDocument.Contains('type')-and$schemaDocument.Contains('additionalProperties')-and$schemaDocument.Contains('required')-and$schemaDocument.Contains('properties')-and[string]$schemaDocument.type-ceq'object'-and$schemaDocument.additionalProperties-is[bool]-and-not[bool]$schemaDocument.additionalProperties-and$unsupportedSchemaKeywords.Count-eq0
$schemaFieldsValid=@($schemaDocument.required).Count-eq$schemaFields.Count-and@($schemaFields|Where-Object{$_-cnotin@($schemaDocument.required)}).Count-eq0-and@($schemaDocument.properties.Keys).Count-eq$schemaFields.Count-and@($schemaFields|Where-Object{-not$schemaDocument.properties.Contains($_)}).Count-eq0
$schemaPropertiesValid=@($schemaDocument.properties.schema_version.Keys).Count-eq2-and[string]$schemaDocument.properties.schema_version.type-ceq'string'-and@($schemaDocument.properties.schema_version.enum).Count-eq1-and[string]$schemaDocument.properties.schema_version.enum[0]-ceq'host-benchmark-observation/v1'-and@($schemaDocument.properties.outcome.Keys).Count-eq2-and[string]$schemaDocument.properties.outcome.type-ceq'string'-and(@($schemaDocument.properties.outcome.enum)-join'|')-ceq'completed|in_progress|blocked|failed'-and@($schemaDocument.properties.reason_code.Keys).Count-eq2-and[string]$schemaDocument.properties.reason_code.type-ceq'string'-and(@($schemaDocument.properties.reason_code.enum)-join'|')-ceq'completed|stage_boundary|missing_decision|capability_block|execution_failed|verification_failed'
foreach($booleanField in @('task_completed','verification_executed','verification_passed')){$schemaPropertiesValid=$schemaPropertiesValid-and@($schemaDocument.properties[$booleanField].Keys).Count-eq1-and[string]$schemaDocument.properties[$booleanField].type-ceq'boolean'}
Check ($schemaRootValid-and$schemaFieldsValid-and$schemaPropertiesValid) 'host observation output schema is outside the exact Structured Outputs root-object subset'
$valid='{"schema_version":"host-benchmark-observation/v1","outcome":"completed","task_completed":true,"verification_executed":true,"verification_passed":true,"reason_code":"completed"}'
Check (Test-Json -Json $valid -SchemaFile $schema -ErrorAction Stop -WarningAction SilentlyContinue) 'valid host observation rejected'
$invalid=$valid -replace ',"verification_passed":true',''
Check (-not(Test-Json -Json $invalid -SchemaFile $schema -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) 'missing host observation field accepted'
$contradictory='{"schema_version":"host-benchmark-observation/v1","outcome":"completed","task_completed":false,"verification_executed":false,"verification_passed":true,"reason_code":"completed"}'
Check (Test-Json -Json $contradictory -SchemaFile $schema -ErrorAction Stop -WarningAction SilentlyContinue) 'Structured Outputs base schema unexpectedly contains cross-field composition'
$runnerText=Get-Content -LiteralPath $runner -Raw -Encoding utf8
$runnerAstTokens=$null;$runnerAstErrors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$runnerAstTokens,[ref]$runnerAstErrors)
$trialAstTokens=$null;$trialAstErrors=$null
$trialAst=[Management.Automation.Language.Parser]::ParseFile($trial,[ref]$trialAstTokens,[ref]$trialAstErrors)
$otelText=Get-Content -LiteralPath $otel -Raw -Encoding utf8
$trialText=Get-Content -LiteralPath $trial -Raw -Encoding utf8
$collectorText=Get-Content -LiteralPath $collector -Raw -Encoding utf8
$text=@($runnerText,$otelText,$trialText,$collectorText)-join"`n"
$wrapperText=Get-Content -LiteralPath $wrapper -Raw -Encoding utf8
$legacyRefs=@(Select-String -LiteralPath @($runner,$trial,(Join-Path $RepoRoot 'tests\verify-host-benchmark-qualification.ps1')) -SimpleMatch 'HostBenchmark.Common')
Check ($legacyRefs.Count-eq0) 'scripts/tests still reference HostBenchmark.Common'
Check ($text-match'Import-Module \$atomicWritePath'-and$text-match'Get-HarnessFileDigest'-and$text-match'Get-HarnessSha256Text'-and$text-match'Write-HarnessAtomicText') 'existing atomic hash/write module is not reused'
$trialResolveStart=$trialText.IndexOf('function Test-HostWorkspaceChangePathsSafe')
$trialResolveEnd=$trialText.IndexOf('function Resolve-HostTrialStatus',$trialResolveStart)
$trialResolveBlock=if($trialResolveStart-ge0-and$trialResolveEnd-gt$trialResolveStart){$trialText.Substring($trialResolveStart,$trialResolveEnd-$trialResolveStart)}else{''}
$workspacePathSafetyFunctions=@($trialAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-HostWorkspaceChangePathsSafe'},$true))
$workspacePathSafetyFunction=if($workspacePathSafetyFunctions.Count-eq1){$workspacePathSafetyFunctions[0]}else{$null}
$workspacePathSafetyPaths=@(if($null-ne$workspacePathSafetyFunction){$workspacePathSafetyFunction.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Paths' }})
$workspacePathSafetyMandatoryAttributes=@(if($workspacePathSafetyPaths.Count-eq1){$workspacePathSafetyPaths[0].Attributes | Where-Object { $_ -is [Management.Automation.Language.AttributeAst] -and $_.TypeName.FullName -ceq 'Parameter' -and $_.Extent.Text -ceq '[Parameter(Mandatory)]' }})
$workspacePathSafetyAllowEmptyAttributes=@(if($workspacePathSafetyPaths.Count-eq1){$workspacePathSafetyPaths[0].Attributes | Where-Object { $_ -is [Management.Automation.Language.AttributeAst] -and $_.TypeName.FullName -ceq 'AllowEmptyCollection' }})
$workspacePathSafetyTypes=@(if($workspacePathSafetyPaths.Count-eq1){$workspacePathSafetyPaths[0].Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] -and $_.TypeName.FullName -ceq 'string[]' }})
$workspacePathSafetySignatureValid=$workspacePathSafetyPaths.Count-eq1-and$workspacePathSafetyMandatoryAttributes.Count-eq1-and$workspacePathSafetyAllowEmptyAttributes.Count-eq1-and$workspacePathSafetyTypes.Count-eq1
$workspacePathSafetyCalls=@(Get-ExactCommandAst -Ast $trialAst -Name 'Test-HostWorkspaceChangePathsSafe')
$workspacePathSafetyCall=if($workspacePathSafetyCalls.Count-eq1){$workspacePathSafetyCalls[0]}else{$null}
$workspacePathSafetyElements=@(if($null-ne$workspacePathSafetyCall){$workspacePathSafetyCall.CommandElements})
$workspacePathSafetyAssignment=if($null-ne$workspacePathSafetyCall-and$workspacePathSafetyCall.Parent.Parent -is [Management.Automation.Language.AssignmentStatementAst]){$workspacePathSafetyCall.Parent.Parent}else{$null}
$workspacePathSafetyCallValid=$workspacePathSafetyElements.Count-eq7-and$workspacePathSafetyElements[1] -is [Management.Automation.Language.CommandParameterAst]-and$workspacePathSafetyElements[1].ParameterName -ceq 'Workspace'-and$workspacePathSafetyElements[2] -is [Management.Automation.Language.VariableExpressionAst]-and$workspacePathSafetyElements[2].VariablePath.UserPath -ceq 'workspace'-and$workspacePathSafetyElements[3] -is [Management.Automation.Language.CommandParameterAst]-and$workspacePathSafetyElements[3].ParameterName -ceq 'Paths'-and$workspacePathSafetyElements[4] -is [Management.Automation.Language.VariableExpressionAst]-and$workspacePathSafetyElements[4].VariablePath.UserPath -ceq 'changed'-and$workspacePathSafetyElements[5] -is [Management.Automation.Language.CommandParameterAst]-and$workspacePathSafetyElements[5].ParameterName -ceq 'PathModule'-and$workspacePathSafetyElements[6] -is [Management.Automation.Language.VariableExpressionAst]-and$workspacePathSafetyElements[6].VariablePath.UserPath -ceq 'pathModule'-and$null-ne$workspacePathSafetyAssignment-and$workspacePathSafetyAssignment.Left -is [Management.Automation.Language.VariableExpressionAst]-and$workspacePathSafetyAssignment.Left.VariablePath.UserPath -ceq 'safeChangedPaths'
Check (@($trialAstErrors).Count-eq0-and$workspacePathSafetyFunctions.Count-eq1-and$workspacePathSafetySignatureValid) 'workspace change safety rejects the valid empty change set before evaluating it'
Check ($workspacePathSafetyCalls.Count-eq1-and$workspacePathSafetyCallValid) 'workspace change safety signature is not bound to the production changed-path evidence'
$invokeHostTrialFunctions=@($trialAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-HostTrial'},$true))
$invokeHostTrialFunction=if($invokeHostTrialFunctions.Count-eq1){$invokeHostTrialFunctions[0]}else{$null}
$observationSemanticFunctions=@($trialAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-HostObservationSemantics'},$true))
$invokeObservationSemanticCalls=@(Get-ExactCommandAst -Ast $invokeHostTrialFunction -Name 'Test-HostObservationSemantics')
$invokeObservationSemanticCall=if($invokeObservationSemanticCalls.Count-eq1){$invokeObservationSemanticCalls[0]}else{$null}
$observationValidationTry=$null
$observationAncestor=if($null-ne$invokeObservationSemanticCall){$invokeObservationSemanticCall.Parent}else{$null}
while($null-ne$observationAncestor-and$observationAncestor-isnot[Management.Automation.Language.TryStatementAst]){$observationAncestor=$observationAncestor.Parent}
if($observationAncestor-is[Management.Automation.Language.TryStatementAst]){$observationValidationTry=$observationAncestor}
$observationValidationBody=if($null-ne$observationValidationTry){$observationValidationTry.Body}else{$null}
$schemaValidationCalls=@(Get-ExactCommandAst -Ast $observationValidationBody -Name 'Test-Json')
$schemaValidationCall=if($schemaValidationCalls.Count-eq1){$schemaValidationCalls[0]}else{$null}
$observationSemanticCalls=@(Get-ExactCommandAst -Ast $observationValidationBody -Name 'Test-HostObservationSemantics')
$observationSemanticCall=if($observationSemanticCalls.Count-eq1){$observationSemanticCalls[0]}else{$null}
$observationSemanticElements=@(if($null-ne$observationSemanticCall){$observationSemanticCall.CommandElements})
$observationSemanticIf=$null
$observationSemanticAncestor=if($null-ne$observationSemanticCall){$observationSemanticCall.Parent}else{$null}
while($null-ne$observationSemanticAncestor-and$observationSemanticAncestor-isnot[Management.Automation.Language.IfStatementAst]){$observationSemanticAncestor=$observationSemanticAncestor.Parent}
if($observationSemanticAncestor-is[Management.Automation.Language.IfStatementAst]){$observationSemanticIf=$observationSemanticAncestor}
$observationAssignments=@(if($null-ne$observationValidationBody){$observationValidationBody.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'observation'},$true)})
$telemetryAssignments=@(if($null-ne$observationValidationBody){$observationValidationBody.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'telemetry'},$true)})
$invalidWrapperStrings=@(if($null-ne$observationValidationTry){$observationValidationTry.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -ceq 'invalid-wrapper-output'},$true)})
$observationSemanticIfValid=$null-ne$observationSemanticIf-and$observationSemanticIf.Clauses.Count-eq1-and$null-eq$observationSemanticIf.ElseClause-and$observationSemanticIf.Clauses[0].Item1.Extent.Text-ceq'-not (Test-HostObservationSemantics -Observation $observation)'-and$observationSemanticIf.Clauses[0].Item2.Statements.Count-eq1-and$observationSemanticIf.Clauses[0].Item2.Statements[0] -is [Management.Automation.Language.ThrowStatementAst]-and$observationSemanticIf.Clauses[0].Item2.Statements[0].Extent.Text-ceq"throw 'invalid observation semantics'"
$observationAssignmentValid=$observationAssignments.Count-eq1-and$observationAssignments[0].Right -is [Management.Automation.Language.PipelineAst]-and$observationAssignments[0].Right.Extent.Text-ceq'$rawObservation | ConvertFrom-Json -AsHashtable -Depth 20'
$observationSemanticCallValid=$null-ne$schemaValidationCall-and$schemaValidationCall.Extent.Text-ceq'Test-Json -Json $rawObservation -SchemaFile $SchemaPath -ErrorAction Stop -WarningAction SilentlyContinue'-and$observationSemanticElements.Count-eq3-and$observationSemanticElements[1] -is [Management.Automation.Language.CommandParameterAst]-and$observationSemanticElements[1].ParameterName -ceq 'Observation'-and$observationSemanticElements[2] -is [Management.Automation.Language.VariableExpressionAst]-and$observationSemanticElements[2].VariablePath.UserPath -ceq 'observation'-and$observationAssignmentValid-and$observationSemanticIfValid-and$telemetryAssignments.Count-eq1-and$schemaValidationCall.Extent.StartOffset-lt$observationAssignments[0].Extent.StartOffset-and$observationAssignments[0].Extent.StartOffset-lt$observationSemanticCall.Extent.StartOffset-and$observationSemanticCall.Extent.StartOffset-lt$telemetryAssignments[0].Extent.StartOffset-and@($observationValidationTry.CatchClauses).Count-eq1-and$invalidWrapperStrings.Count-eq1
Check ($invokeHostTrialFunctions.Count-eq1-and$observationSemanticFunctions.Count-eq1-and$invokeObservationSemanticCalls.Count-eq1-and$null-ne$observationValidationTry-and$schemaValidationCalls.Count-eq1-and$observationSemanticCalls.Count-eq1-and$observationSemanticCallValid) 'host observation schema and cross-field semantics are not fail-closed in one validation try'
$pathModuleCaptureIndex=$trialText.IndexOf('$pathModule = @(Get-Module Harness.Path')
$protocolForceIndex=$trialText.IndexOf("Import-Module (Join-Path `$RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force")
Check ($pathModuleCaptureIndex-ge0-and$protocolForceIndex-gt$pathModuleCaptureIndex-and$trialResolveBlock-match'&\s*\$PathModule\s*\{[^}]*Resolve-HarnessContainedPath') 'Trial changed-path safety still depends on the replaceable global Harness.Path command'
$trialInvokeStart=$runnerText.IndexOf('$record = Invoke-HostTrial')
$trialInvokeEnd=$runnerText.IndexOf('$installedCleanupFailed =',$trialInvokeStart)
$trialInvokeBlock=if($trialInvokeStart-ge0-and$trialInvokeEnd-gt$trialInvokeStart){$runnerText.Substring($trialInvokeStart,$trialInvokeEnd-$trialInvokeStart)}else{''}
$atomicReloadIndex=$trialInvokeBlock.IndexOf('Import-Module $atomicWritePath -Force')
$pathReloadIndex=$trialInvokeBlock.IndexOf('Import-Module $pathModulePath -Force')
Check ($trialInvokeBlock-match'finally\s*\{'-and$atomicReloadIndex-ge0-and$pathReloadIndex-gt$atomicReloadIndex) 'runner does not restore AtomicWrite then Path after every trial return or exception'
Check ($runnerText-match"gpt-5\.6-sol"-and$runnerText-match"ValidateSet\('max'\)"-and$trialText-match"'\-Sandbox','danger-full-access','\-ApprovalPolicy','never','\-Ephemeral'"-and$trialText-match'if \(\$installedMode\) \{ \$wrapperArguments \+= ''\-LoadUserConfig'' \} else \{ \$wrapperArguments \+= ''\-Isolated'' \}') 'release model/max or explicit cognitive/installed invocation contract missing'
Check ($text-match'\$protocolNames = @\(''bare'',''v1'',''v2''\)'-and$text-match'HARNESS_PROTOCOL = \$Protocol'-and$text-match'fresh_ephemeral_session_per_invocation=\$true') 'bare/v1/v2 fresh-session comparison contract missing'
Check ($text-match'install_duration_included=\$false'-and$text-match'total_duration_ms'-and$text-match'sum_codex_process_duration_ms'-and$text-match'first_useful_action_ms'-and$text-match'successful_request_sends'-and$text-match'loaded_files'-and$text-match'artifact_writes'-and$text-match'runtime_writes'-and$text-match'tokens') 'required host metrics or latency boundary missing'
Check ($text-match'ratio-le1\.25'-and$text-match'threshold=0\.60'-and$text-match'\$gateUnavailable'-and$text-match'not \$sourceDirty'-and$text-match'\$sourceStable') 'measured performance thresholds or fail-closed source rule missing'
Check ($text-match'Initialize-V1FixedWorkflowFixture'-and$text-match"stage: PLAN"-and$text-match"status: confirmed"-and$text-match'Test-V1FixedWorkflowComplete'-and$text-match"'confirmed-plan-to-done-one-stage-per-host-turn'") 'v1 comparator is not a confirmed fixed workflow required to reach DONE'
Check ($text-match'do not route it as quick'-and$text-match'bare_and_v2_start=.new-task.'-and$text-match"semantic_task='change exact private file bytes and verify'") 'fixed-workflow comparator identity or same semantic task contract missing'
Check ($text-match'prompt_persisted=\$false'-and$text-match'raw_command_persisted=\$false'-and$text-match'thread_id_persisted=\$false'-and$text-match'report_digest') 'sanitized source-bound report contract missing'
Check ($text-match'hostTurns \+= \[int\]\$telemetry\.model_turns'-and$text-match'agentMessages \+= \[int\]\$telemetry\.agent_messages'-and$text-match"basis='codex-jsonl-turn.started'"-and$text-match"successful_request_send_measurement='codex-0.144.4-successful-websocket-send/v2'") 'host-turn diagnostic or successful-request-send contract missing'
Check ($text-notmatch'modelRoundTrips \+='-and$text-notmatch'host_turns\.value.*model_roundtrip'-and$text-match'model_client\.stream_responses_websocket'-and$text-match'websocket\.warmup'-and$text-match'otel-model-transport-unsupported') 'host turns or an unvalidated transport can still satisfy the model-request gate'
Check ($text-match'\$groupRecords\.v1\.successful_request_sends\.median'-and$text-match'\$groupRecords\.v2\.successful_request_sends\.median'-and$text-match'reduction-ge0\.60') '60 percent gate is not computed independently from each group measured successful-request-send medians'
Check ($text-match'\$trialTimer = \[Diagnostics\.Stopwatch\]::StartNew\(\)'-and$text-match'\$invocationOffsetMs = \$trialTimer\.Elapsed\.TotalMilliseconds'-and$text-match'\$trialTimer\.Stop\(\)') 'whole-trial timing or first-useful-action offset is missing'
Check ($runnerText-match'Get-HostGitState'-and$runnerText-match'git-revision-tree-status/v1'-and$runnerText-match'commit_tree_oid'-and$runnerText-match'Test-HostGitFileMatchesRevision'-and$runnerText-match'git-hash-object-equals-revision-blob/v1'-and$runnerText-match'input_head_binding'-and$trialText-match'git -c core\.longpaths=true clone --no-local --no-checkout'-and$trialText-match"checkout','--quiet','--detach'"-and$trialText-match'git-head-tree-clean/v1') 'native clean-commit source or live-input HEAD binding is missing'
Check ($text-match'\$rotation = \(\(\$groupIndex - 1\) \+ \(\$trial - 1\)\) % \$protocolNames\.Count'-and$text-match"group_order_strategy='independent-groups-round-interleaved-rotating-start'"-and$text-match"schema_version='harness-host-benchmark-report/v2'"-and$text-match'group_run_id=\$groupRunId'-and$text-match'group_root_digest=\$groupRootDigest'-and$text-match'\$record\[''trial_run_id''\] = \$trialRunId'-and$text-match'\$record\[''trial_root_digest''\] = \$trialRootDigest'-and$text-match'actual_trial_order=@\(\$executionOrder\)'-and$text-match"cache_state='shared-dedicated-auth-home-and-host-cache-not-cleared-between-trials'") 'independent grouped 3x3 order, group/trial namespace identity, or cache limitation is missing'
Check ($text-match"loaded_skills\s*=\s*\[ordered\]@\{status='unavailable'"-and$text-match"skill_file_command_matches\s*=\s*\[ordered\]@\{status='measured'") 'skill-file command heuristic is still presented as authoritative loaded skills'
Check ($runnerText-match'\$groupKnownFailure = \$protocolFailed -or \$groupConfigurationFailure -or \$groupPerformanceFailure'-and$runnerText-match'AllowUnavailableRecord'-and$runnerText-match'if \(\$groupKnownFailure\) \{ ''fail'' \} elseif \(\$protocolUnavailable -or -not \$groupSourceStable -or \$gateUnavailable\)'-and$runnerText-match'\$eligible = \$sourceStable.*\$benchmarkGroups\.Count -eq 3.*\$passedGroups -eq 3'-and$runnerText-match'if \(\[string\]\$report\.status -ceq ''unavailable''\).*exit 2'-and$trialText-match'function Resolve-HostTrialStatus'-and$trialText-match'\$directObservedFailure'-and$trialText-match'\$v1ObservedFailure'-and$trialText-match'if \(\$InvocationUnavailable\) \{ return ''unavailable'' \}') 'group fail/unavailable precedence, three-group conjunction, or deterministic exit contract is missing'
Check ($wrapperText-match'OtelTraceEndpoint'-and$wrapperText-match'127\.0\.0\.1'-and$wrapperText-match'otel\.trace_exporter'-and$wrapperText-match'otel\.exporter="none"'-and$wrapperText-match'otel\.metrics_exporter="none"') 'loopback-only trace exporter wrapper contract missing'
Check ($wrapperText-match'OtelClientIdentityPath'-and$wrapperText-match'Register-CodexOtelClient'-and$wrapperText-match'Get-CodexOtelClientIdentity'-and$wrapperText-match'start_time_filetime_utc'-and$wrapperText-match'OTLP collector did not acknowledge.*before the prompt'-and$trialText-match'OtelCollectorInstanceId'-and$trialText-match'verified-owner-pid-start-time/v1'-and$otelText-match'Test-OtlpTraceManifest'-and$otelText-match'collector manifest channel was not exact'-and$collectorText-match'\[Environment\]::SystemDirectory'-and$collectorText-match'netstat\.exe'-and$collectorText-match'expectedLocalEndpoint'-and$collectorText-match'expectedRemoteEndpoint'-and$collectorText-match'\$owners\.Count -gt 1'-and$collectorText-match'owner lookup returned no process'-and$collectorText-match'Resolve-ConnectionRegistration'-and$collectorText-match'FileShare\]::Read') 'pre-prompt process provenance or authenticated trace manifest chain is incomplete'
Check ($collectorText-notmatch'(?i)Add-Type|DllImport|GetExtendedTcpTable|Marshal\.|Get-NetTCPConnection'-and$collectorText-notmatch'(?i)ExecutionPolicy|Bypass|CreateNoWindow'-and$otelText-notmatch'(?i)ExecutionPolicy|Bypass|CreateNoWindow') 'OTLP owner/launch chain is dynamically compiled, opaque, or policy-bypassing'
Check ($wrapperText-notmatch "(?i)'-EncodedCommand'|'-Command'" -and $wrapperText-match 'InternalShimArgumentsJson' -and $wrapperText-match 'Internal shim path must match the resolved Codex command' -and $wrapperText-match 'EnvironmentOverrides = @\{ CODEX_EXECUTABLE = \$path \}' -and $wrapperText-match [regex]::Escape("'-File', `$PSCommandPath, '-InternalShimPath', `$path")) 'Codex PowerShell shim launch is not a transparent structured -File invocation bound to Codex'
Check ($otelText-match'Confirm-OtlpProcessExit'-and$otelText-match'cleanup_pending'-and$trialText-match'HostPendingOtlpCollectors'-and$trialText-match'Complete-HostPendingOtlpCleanup'-and$runnerText-match'OTLP collector or raw trace cleanup remained pending'-and$trialText-notmatch "collector\.status -ceq 'measured'.*Stop-OtlpCollector") 'collector failure cleanup can discard a live process handle, skip an early exit, or retain raw trace'
$pendingCompletionIndex = $runnerText.IndexOf('$pendingCleanupFailures =')
$protocolAggregationIndex = $runnerText.IndexOf('foreach ($protocol in $protocolNames)')
$v1RoundContractPatterns = @(
    "(?m)^\s*'PLAN'\s*\{\s*\r?\n\s*return \[ordered\]@\{next_stage='PLAN_REVIEW';expected_target='alpha';target_action='preserve';stage_action='Complete only the PLAN work for the confirmed task\.'\}\s*\r?\n\s*\}\s*$",
    "(?m)^\s*'PLAN_REVIEW'\s*\{\s*\r?\n\s*return \[ordered\]@\{next_stage='IMPLEMENT';expected_target='alpha';target_action='preserve';stage_action='Complete only the PLAN_REVIEW work for the confirmed task\.'\}\s*\r?\n\s*\}\s*$",
    "(?m)^\s*'IMPLEMENT'\s*\{\s*\r?\n\s*return \[ordered\]@\{next_stage='CODE_REVIEW';expected_target='beta';target_action='change';stage_action='Complete only the IMPLEMENT work for the confirmed task\.'\}\s*\r?\n\s*\}\s*$",
    "(?m)^\s*'CODE_REVIEW'\s*\{\s*\r?\n\s*return \[ordered\]@\{next_stage='TEST';expected_target='beta';target_action='preserve';stage_action='Complete only the CODE_REVIEW work for the confirmed task\.'\}\s*\r?\n\s*\}\s*$",
    "(?m)^\s*'TEST'\s*\{\s*\r?\n\s*return \[ordered\]@\{next_stage='DONE';expected_target='beta';target_action='preserve';stage_action='Complete only the TEST work for the confirmed task\.'\}\s*\r?\n\s*\}\s*$"
)
$v1RoundContractsExact = @($v1RoundContractPatterns | Where-Object { @([regex]::Matches($trialText,$_)).Count -ne 1 }).Count -eq 0
$v1RoundContractMutation = $trialText.Replace("next_stage='PLAN_REVIEW';expected_target='alpha';target_action='preserve';stage_action='Complete only the PLAN work for the confirmed task.'","next_stage='PLAN_REVIEW';expected_target='alpha';target_action='change';stage_action='Complete only the PLAN work for the confirmed task.'")
$v1RoundContractMutationRejected = $v1RoundContractMutation -cne $trialText -and @($v1RoundContractPatterns | Where-Object { @([regex]::Matches($v1RoundContractMutation,$_)).Count -ne 1 }).Count -gt 0
$v1TargetDirectivePattern = '(?ms)^\s*\$targetDirective = if \(\[string\]\$v1RoundContract\.target_action -ceq ''change''\) \{\s*\r?\n\s*"Change only src/value\.txt from exactly alpha to exactly \$v1ExpectedTarget, then verify that its exact bytes are \$v1ExpectedTarget\."\s*\r?\n\s*\} else \{\s*\r?\n\s*"Do not change src/value\.txt; verify that its exact bytes remain \$v1ExpectedTarget\."\s*\r?\n\s*\}'
$v1TargetDirectiveExact = @([regex]::Matches($trialText,$v1TargetDirectivePattern)).Count -eq 1
$v1TargetDirectiveMutation = $trialText.Replace('verify that its exact bytes remain $v1ExpectedTarget.','verify that its exact bytes remain beta.')
$v1TargetDirectiveMutationRejected = $v1TargetDirectiveMutation -cne $trialText -and @([regex]::Matches($v1TargetDirectiveMutation,$v1TargetDirectivePattern)).Count -ne 1
$v1ChangeDirectiveMutation = $trialText.Replace('from exactly alpha to exactly $v1ExpectedTarget, then verify that its exact bytes are $v1ExpectedTarget.','from exactly alpha to exactly beta, then verify that its exact bytes are beta.')
$v1ChangeDirectiveMutationRejected = $v1ChangeDirectiveMutation -cne $trialText -and @([regex]::Matches($v1ChangeDirectiveMutation,$v1TargetDirectivePattern)).Count -ne 1
$v1TargetConditionMutation = $trialText.Replace("`$v1RoundContract.target_action -ceq 'change'","`$v1RoundContract.target_action -cne 'change'")
$v1TargetConditionMutationRejected = $v1TargetConditionMutation -cne $trialText -and @([regex]::Matches($v1TargetConditionMutation,$v1TargetDirectivePattern)).Count -ne 1
$v1TaskActionBindingPattern = "(?m)^\s*\(\[string\]\`$v1RoundContract\.stage_action \+ ' ' \+ \`$targetDirective\)\s*`$"
$v1TaskActionBindingExact = @([regex]::Matches($trialText,$v1TaskActionBindingPattern)).Count -eq 1
$v1TaskActionBindingMutation = $trialText.Replace("([string]`$v1RoundContract.stage_action + ' ' + `$targetDirective)","'Change only src/value.txt from exactly alpha to exactly beta.'")
$v1TaskActionBindingMutationRejected = $v1TaskActionBindingMutation -cne $trialText -and @([regex]::Matches($v1TaskActionBindingMutation,$v1TaskActionBindingPattern)).Count -ne 1
$v1RouteBranchPattern = "(?m)^\s*\`$routeContext = if \(\`$Protocol -ceq 'v1'\) \{\s*`$"
$v1TaskActionBranchPattern = "(?m)^\s*\`$taskAction = if \(\`$Protocol -ceq 'v1'\) \{\s*`$"
$v1PromptBranchesExact = @([regex]::Matches($trialText,$v1RouteBranchPattern)).Count -eq 1 -and @([regex]::Matches($trialText,$v1TaskActionBranchPattern)).Count -eq 1 -and $trialText -match 'current stage \$v1StageBefore and advance exactly once to \$v1ExpectedStage'
$v1RouteBranchMutation = $trialText.Replace("`$routeContext = if (`$Protocol -ceq 'v1') {","`$routeContext = if (`$Protocol -cne 'v1') {")
$v1TaskActionBranchMutation = $trialText.Replace("`$taskAction = if (`$Protocol -ceq 'v1') {","`$taskAction = if (`$Protocol -cne 'v1') {")
$v1PromptBranchMutationsRejected = $v1RouteBranchMutation -cne $trialText -and @([regex]::Matches($v1RouteBranchMutation,$v1RouteBranchPattern)).Count -ne 1 -and $v1TaskActionBranchMutation -cne $trialText -and @([regex]::Matches($v1TaskActionBranchMutation,$v1TaskActionBranchPattern)).Count -ne 1
$v1RoundLookupPattern = "(?m)^\s*\`$v1RoundContract = if \(\`$Protocol -ceq 'v1'\) \{ Get-V1FixedWorkflowRoundContract -Stage \`$v1StageBefore \} else \{ \`$null \}\s*`$"
$v1ExpectedStagePattern = '(?m)^\s*\$v1ExpectedStage = if \(\$null -ne \$v1RoundContract\) \{ \[string\]\$v1RoundContract\.next_stage \} else \{ '''' \}\s*$'
$v1ExpectedTargetPattern = '(?m)^\s*\$v1ExpectedTarget = if \(\$null -ne \$v1RoundContract\) \{ \[string\]\$v1RoundContract\.expected_target \} else \{ '''' \}\s*$'
$v1RoundWiringExact = @([regex]::Matches($trialText,$v1RoundLookupPattern)).Count -eq 1 -and @([regex]::Matches($trialText,$v1ExpectedStagePattern)).Count -eq 1 -and @([regex]::Matches($trialText,$v1ExpectedTargetPattern)).Count -eq 1
$v1RoundLookupMutation = $trialText.Replace('Get-V1FixedWorkflowRoundContract -Stage $v1StageBefore',"Get-V1FixedWorkflowRoundContract -Stage 'IMPLEMENT'")
$v1RoundLookupMutationRejected = $v1RoundLookupMutation -cne $trialText -and @([regex]::Matches($v1RoundLookupMutation,$v1RoundLookupPattern)).Count -ne 1
$v1ExpectedTargetMutation = $trialText.Replace('[string]$v1RoundContract.expected_target','''beta''')
$v1ExpectedTargetMutationRejected = $v1ExpectedTargetMutation -cne $trialText -and @([regex]::Matches($v1ExpectedTargetMutation,$v1ExpectedTargetPattern)).Count -ne 1
$v1PostconditionPattern = '(?m)^\s*if \(\$v1StageAfter -cne \$v1ExpectedStage -or \$v1TargetAfter -cne \$v1ExpectedTarget -or -not \(Test-V1RuntimeState\b'
$v1PostconditionExact = @([regex]::Matches($trialText,$v1PostconditionPattern)).Count -eq 1
$v1PostconditionMutation = $trialText.Replace('$v1TargetAfter -cne $v1ExpectedTarget',"`$v1TargetAfter -cne 'beta'")
$v1PostconditionMutationRejected = $v1PostconditionMutation -cne $trialText -and @([regex]::Matches($v1PostconditionMutation,$v1PostconditionPattern)).Count -ne 1
Check ($pendingCompletionIndex -ge 0 -and $protocolAggregationIndex -gt $pendingCompletionIndex) 'pending cleanup does not finish before protocol aggregation'
Check ($text-match'Content-Length'-and$text-match'67108864'-and$text-match'request-\{0:d4\}'-and$text-notmatch'\bnode\b'-and$text-notmatch'\bpython\b') 'dependency-free bounded OTLP receiver contract missing'
Check ($runnerText-match'raw_trace_persisted=\$\(if\(\$groupRawTraceCleanupConfirmed\)'-and$runnerText-match'raw_trace_cleanup_confirmed=\$groupRawTraceCleanupConfirmed'-and$runnerText-match'raw_trace_deleted'-and$trialText-match'-SafetyRoot \$trialRoot'-and$runnerText-match'otlp_collector_digest'-and$runnerText-match'atomic_write_module_digest'-and$runnerText-match'path_module_digest'-and$runnerText-match'otel_contract_digest'-and$runnerText-match'trial_helper_digest') 'raw trace privacy or source-input binding missing'
Check ($trialText-match'function Get-V1FixedWorkflowRoundContract'-and$v1RoundContractsExact-and$v1RoundContractMutationRejected-and$v1TargetDirectiveExact-and$v1TargetDirectiveMutationRejected-and$v1ChangeDirectiveMutationRejected-and$v1TargetConditionMutationRejected-and$v1TaskActionBindingExact-and$v1TaskActionBindingMutationRejected-and$v1PromptBranchesExact-and$v1PromptBranchMutationsRejected-and$v1RoundWiringExact-and$v1RoundLookupMutationRejected-and$v1ExpectedTargetMutationRejected-and$v1PostconditionExact-and$v1PostconditionMutationRejected-and$trialText-match'\$routeContext \$taskAction'-and$trialText-notmatch'\$routeContext Change only src/value\.txt'-and$text-match'advance exactly once'-and$text-match"lastReason -cne 'stage_boundary'"-and$text-match'Test-V1RuntimeState'-and$text-match'PLAN_REVIEW>IMPLEMENT>CODE_REVIEW>TEST>DONE'-and$text-match'alpha>alpha>beta>beta>beta'-and$text-match"diagnostic = 'v1-stage-boundary-violation'") 'v1 per-stage prompt, one-stage-per-host-turn, or target-timing boundary is not fail closed'
Check ($trialText-match'Assert-HostCodexHomeLayout'-and$runnerText-match'HOST_BENCHMARK_CODEX_HOME'-and$trialText-match'ReparsePoint'-and$trialText-match"@\('auth.json','models_cache.json'"-and$trialText-match'host-benchmark-auth-home-linked-credential'-and$trialText-match'Get-HostFileSystemIdentity'-and$trialText-match'fsutil file queryFileID'-and$trialText-match'mountvol'-and$trialText-match'host-benchmark-auth-home-unsafe-location'-and$trialText-match'AllowNativeSystemSkills'-and$trialText-match'AllowIsolatedHostConfig'-and$trialText-match'HostIsolatedConfigSentinelText'-and$trialText-match'HostIsolatedConfigOwnerPrefix'-and$trialText-match'FileMode\]::CreateNew'-and$trialText-match'File\]::Move\(\$tempPath,\$configPath,\$false\)'-and$trialText-match'FileAttributes\]::ReadOnly'-and$trialText-match'function Recover-HostIsolatedConfigSentinel'-and$trialText-match'function Enter-HostCodexHomeMutex'-and$trialText-match'Global\\dev-harness\.host-benchmark\.'-and$trialText-match'406e58b4e35d949e'-and$trialText-match"'CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY','CODEX_EXECUTABLE','CODEX_THREAD_ID','CODEX_INTERNAL_ORIGINATOR_OVERRIDE','CODEX_SHELL'"-and$runnerText-match'Get-HostPhysicalPathInfo'-and$runnerText-match'Host benchmark output must not overlap the dedicated Codex home'-and$wrapperText-match'--ignore-user-config'-and$wrapperText-match'skills\.enabled=false') 'dedicated config-isolated Codex home or physical-identity contract is missing'
Check ($trialText-match'Assert-HostCodexHome -Path \$CodexHome -RepoRoot \$RepoRoot -ScratchRoot \$ScratchRoot -AllowNativeSystemSkills -AllowIsolatedHostConfig'-and$trialText-match'else \{ \$null = Assert-HostCodexHomeLayout -Path \$CodexHome -AllowNativeSystemSkills -AllowIsolatedHostConfig \}') 'cognitive Host does not require strict native skills and exact sentinel on both initial and final layout checks'
Check ($trialText.Contains("'-ExpectedCodexVersion',`$ExpectedCodexVersion")-and$trialText-match"telemetry\.schema_version -cne 'codex-invocation-telemetry/v2'"-and$trialText-match'telemetry\.codex_cli_version -cne \$ExpectedCodexVersion') 'Host wrapper invocation or telemetry is not bound to the expected Codex CLI version'
$cognitiveIfAsts=@($runnerAst.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '^if \(\$BenchmarkPath -ceq ''cognitive-fast-path'' -and -not \[string\]::IsNullOrWhiteSpace\(\$CodexHome\)\)'},$true))
$cognitiveIfAst=if($cognitiveIfAsts.Count-eq1){$cognitiveIfAsts[0]}else{$null}
$cognitiveBlockAst=if($null-ne$cognitiveIfAst){$cognitiveIfAst.Clauses[0].Item2}else{$null}
$outerTryAsts=@($runnerAst.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $null-ne$node.Finally},$true) | Where-Object { @(Get-ExactCommandAst -Ast $_.Body -Name 'Enter-HostCodexHomeMutex').Count -eq 1 -and @(Get-ExactCommandAst -Ast $_.Finally -Name 'Exit-HostCodexHomeMutex').Count -eq 1 })
$outerTryAst=if($outerTryAsts.Count-eq1){$outerTryAsts[0]}else{$null}
$outerBodyAst=if($null-ne$outerTryAst){$outerTryAst.Body}else{$null};$outerFinallyAst=if($null-ne$outerTryAst){$outerTryAst.Finally}else{$null}
$hostLock=@(Get-ExactCommandAst -Ast $outerBodyAst -Name 'Enter-HostCodexHomeMutex')
$hostRecover=@(Get-ExactCommandAst -Ast $outerBodyAst -Name 'Recover-HostIsolatedConfigSentinel')
$hostInitialize=@(Get-ExactCommandAst -Ast $outerBodyAst -Name 'Initialize-HostIsolatedConfigSentinel')
$hostComplete=@(Get-ExactCommandAst -Ast $outerFinallyAst -Name 'Complete-HostIsolatedConfigSentinel')
$hostExit=@(Get-ExactCommandAst -Ast $outerFinallyAst -Name 'Exit-HostCodexHomeMutex')
$cognitiveRecover=@(Get-ExactCommandAst -Ast $cognitiveBlockAst -Name 'Recover-HostIsolatedConfigSentinel')
$cognitiveTestPath=@(Get-ExactCommandAst -Ast $cognitiveBlockAst -Name 'Test-Path')
$cognitiveGuards=@(Get-ExactCommandAst -Ast $cognitiveBlockAst -Name 'Assert-HostCodexHome')
$cognitiveInitialize=@(Get-ExactCommandAst -Ast $cognitiveBlockAst -Name 'Initialize-HostIsolatedConfigSentinel')
$hostOrderValid=$hostLock.Count-eq1-and$hostRecover.Count-eq1-and$hostInitialize.Count-eq1-and$hostComplete.Count-eq1-and$hostExit.Count-eq1-and$hostLock[0].Extent.StartOffset-lt$hostRecover[0].Extent.StartOffset-and$hostRecover[0].Extent.StartOffset-lt$hostInitialize[0].Extent.StartOffset-and$hostComplete[0].Extent.StartOffset-lt$hostExit[0].Extent.StartOffset
$cognitiveOrderValid=$cognitiveIfAsts.Count-eq1-and$cognitiveRecover.Count-eq1-and$cognitiveTestPath.Count-eq1-and$cognitiveGuards.Count-eq2-and$cognitiveInitialize.Count-eq1-and$cognitiveRecover[0].Extent.StartOffset-lt$cognitiveTestPath[0].Extent.StartOffset-and$cognitiveTestPath[0].Extent.StartOffset-lt$cognitiveGuards[0].Extent.StartOffset-and$cognitiveGuards[0].Extent.StartOffset-lt$cognitiveInitialize[0].Extent.StartOffset-and$cognitiveInitialize[0].Extent.StartOffset-lt$cognitiveGuards[1].Extent.StartOffset-and$cognitiveGuards[0].Extent.Text-match'AllowNativeSystemSkills -AllowIsolatedHostConfig:\$configExists'-and$cognitiveGuards[1].Extent.Text-match'AllowNativeSystemSkills -AllowIsolatedHostConfig'
Check (@($runnerAstErrors).Count-eq0-and$outerTryAsts.Count-eq1-and$hostOrderValid-and$cognitiveOrderValid-and$trialText-match'ReleaseMutex\(\)'-and$trialText-match'\.Dispose\(\)') 'profile lock/recovery/initialization is not ordered in executable AST inside the outer cognitive path or completion does not precede unlock inside the outer finally'
Check ($runnerText-match'ValidateSet\(''cognitive-fast-path'',''installed-desktop-path''\)\]\[string\]\$BenchmarkPath = ''cognitive-fast-path'''-and$trialText-match'ValidateSet\(''cognitive-fast-path'',''installed-desktop-path''\)\]\[string\]\$BenchmarkPath = ''cognitive-fast-path'''-and$runnerText-match"schema_version='harness-host-benchmark-report/v2'"-and$wrapperText-match'if \(-not \$LoadUserConfig\) \{ \$codexArgs\.Add\(''--ignore-user-config''\) \}') 'cognitive benchmark default, isolated user-config behavior, or v2 report identity changed'
Check ($trialText-match'\$installedMode = \$BenchmarkPath -ceq ''installed-desktop-path'''-and$runnerText-match'-BenchmarkPath \$BenchmarkPath'-and$runnerText-notmatch'EligibilityReportPath'-and$trialText-notmatch'EligibilityReportPath'-and$wrapperText-match'if \(\$LoadUserConfig -and \$Isolated\) \{ throw ''-LoadUserConfig cannot be combined with -Isolated\.'' \}'-and$wrapperText-match'if \(\$LoadUserConfig\) \{ \$telemetry\[''user_config_mode''\] = ''loaded'' \}'-and@([regex]::Matches($wrapperText,'user_config_mode')).Count-eq1) 'installed path still accepts rollout eligibility or lost its user-config contract'
Check ($trialText-match'\$env:USERPROFILE = \$profileRoot'-and$trialText-match'\$env:HOME = \$profileRoot'-and$trialText-match'\$env:CODEX_HOME = \$CodexHome'-and$trialText-match'GetFileName\(\$resolved\) -cne ''\.codex'''-and$trialText-match'Remove-Item Env:HARNESS_PROTOCOL,Env:HARNESS_V2_ELIGIBILITY_REPORT'-and$trialText-match'foreach \(\$name in @\(''HARNESS_PROTOCOL'',''HARNESS_V2_ELIGIBILITY_REPORT'',''DEV_HARNESS_WORKSPACE_ROOT'',''WORKSPACE_ROOT''\)\)'-and$trialText-match'host-benchmark-installed-protocol-environment-leaked') 'installed profile roots are not co-sourced or protocol/report environment is not fail closed'
Check ($trialText-match'install\.ps1''\) -WorkspaceRoot \$Workspace -RepoRoot \$RepoRoot -Preset core'-and$trialText-match'verify-installation\.ps1''\) -WorkspaceRoot \$Workspace -RepoRoot \$RepoRoot -UserProfileRoot \$profileRoot -Scope All'-and$trialText-match'host-benchmark-installed-install-changed-auth'-and$trialText-match'host-benchmark-installed-verification-failed') 'installed Core install, verification, or auth-preservation contract is missing'
Check ($trialText-match'function Enable-InstalledDesktopWorkspaceV2'-and$trialText-match'''enable-v2'''-and$trialText-match'preference_source -ceq ''workspace-config'''-and$trialText-match'reason -ceq ''workspace-v2-new-task'''-and$trialText-notmatch'Invoke-InstalledDesktopRolloutPromotion'-and$trialText-notmatch'promote-v2-rollout-report\.ps1'-and$trialText-notmatch'eligible-rollout-report') 'installed v2 does not use workspace enable-v2 exclusively before its route probe'
$runnerEvidenceIndex=$runnerText.IndexOf('$runnerEvidencePassed = Test-HostRunnerTrialEvidence')
$installedCleanupIndex=$runnerText.IndexOf('Invoke-InstalledDesktopTrialCleanup -CodexHome')
Check ($runnerEvidenceIndex-ge0-and$installedCleanupIndex-gt$runnerEvidenceIndex-and$runnerText-match'\$cleanupStatus = ''failed'''-and$runnerText-match'\$record\[''status''\] = ''fail''') 'installed cleanup does not run after runner evidence or cannot fail the trial closed'
$installFunctionStart=$trialText.IndexOf('function Invoke-InstalledDesktopInstall')
$installFunctionEnd=$trialText.IndexOf('function Invoke-InstalledDesktopRouteProbe',$installFunctionStart)
$installFunctionBlock=if($installFunctionStart-ge0-and$installFunctionEnd-gt$installFunctionStart){$trialText.Substring($installFunctionStart,$installFunctionEnd-$installFunctionStart)}else{''}
$installCallIndex=$installFunctionBlock.IndexOf('$installCommandOutput =')
$installFailureIndex=$installFunctionBlock.IndexOf("host-benchmark-installed-install-failed")
$verifyCallIndex=$installFunctionBlock.IndexOf('$verifyOutput =')
$installReturnIndex=$installFunctionBlock.LastIndexOf('return [ordered]@{')
$installPreBlock=if($installCallIndex-gt0){$installFunctionBlock.Substring(0,$installCallIndex)}else{''}
$installImmediateBlock=if($installFailureIndex-gt$installCallIndex){$installFunctionBlock.Substring($installCallIndex,$installFailureIndex-$installCallIndex)}else{''}
$installVerifyBlock=if($installReturnIndex-gt$verifyCallIndex){$installFunctionBlock.Substring($verifyCallIndex,$installReturnIndex-$verifyCallIndex)}else{''}
Check ($installPreBlock-match'Get-FileHash -LiteralPath \$authPath'-and$installPreBlock-match'Get-InstalledDesktopUserConfigBinding'-and$installImmediateBlock-match'\$installExit\w*\s*=\s*\$LASTEXITCODE'-and$installImmediateBlock-match'Get-FileHash -LiteralPath \$authPath'-and$installImmediateBlock-match'Get-InstalledDesktopUserConfigBinding'-and$installImmediateBlock-match'Test-InstalledDesktopUserConfigBinding'-and$installVerifyBlock-match'Get-FileHash -LiteralPath \$authPath'-and$installVerifyBlock-match'Get-InstalledDesktopUserConfigBinding'-and$installVerifyBlock-match'Test-InstalledDesktopUserConfigBinding') 'installed install/verification does not compare immediate auth and config snapshots before interpreting child exit status'
$integrityBlockStart=$runnerText.IndexOf('$installedIntegrityFailed =',$trialInvokeStart)
$integrityBlockEnd=$runnerText.IndexOf('if ($installedCleanupFailed -or $installedIntegrityFailed)',$integrityBlockStart)
$integrityBlock=if($integrityBlockStart-ge0-and$integrityBlockEnd-gt$integrityBlockStart){$runnerText.Substring($integrityBlockStart,($runnerText.IndexOf("`n",$integrityBlockEnd)-$integrityBlockStart))}else{''}
Check ($integrityBlock-match'host-benchmark-installed-.*(?:changed-auth|changed-config)'-and$integrityBlock-match'\$installedIntegrityFailed\s*=.*-cmatch'-and$integrityBlock-match"\['status'\]\s*=\s*'fail'"-and$integrityBlock-match'if \(\$installedCleanupFailed -or \$installedIntegrityFailed\) \{ throw') 'installed auth/config integrity failures do not fail the record and stop subsequent trials'
Check ($runnerText-match'if \(\$BenchmarkPath -ceq ''installed-desktop-path''\) \{'-and$runnerText-match'\$report\.schema_version = ''harness-installed-desktop-benchmark-report/v1'''-and$runnerText-match"hook_trust='manual'"-and$runnerText-match"hook_callability='manual'"-and$runnerText-match'\$report\[''producer_mode''\] = \$producerMode') 'installed report identity is not independent or manual hook observations changed'
$groupProjectionStart=$runnerText.IndexOf('$measurementPassed =',$runnerText.IndexOf('$groupEligible ='))
$groupProjectionEnd=$runnerText.IndexOf('$group.group_digest =',$groupProjectionStart)
$groupProjection=if($groupProjectionStart-ge0-and$groupProjectionEnd-gt$groupProjectionStart){$runnerText.Substring($groupProjectionStart,$groupProjectionEnd-$groupProjectionStart)}else{''}
$reportProjectionStart=$runnerText.IndexOf("if (`$BenchmarkPath -ceq 'installed-desktop-path') {",$runnerText.IndexOf('$report = [ordered]@{'))
$reportProjectionEnd=$runnerText.IndexOf('$report.report_digest =',$reportProjectionStart)
$reportProjection=if($reportProjectionStart-ge0-and$reportProjectionEnd-gt$reportProjectionStart){$runnerText.Substring($reportProjectionStart,$reportProjectionEnd-$reportProjectionStart)}else{''}
Check ($groupProjection-match'measurement_passed'-and$groupProjection-match'\$producerMode -cne ''formal'''-and$groupProjection-match'eligible'-and$groupProjection-match'\$false'-and$groupProjection-match'unavailable') 'non-formal installed groups can become qualification pass/eligible'
Check ($reportProjection-match'measurement_passed'-and$reportProjection-match'\$producerMode-ceq''formal'''-and$reportProjection-match'qualification'-and$reportProjection-match'unavailable'-and$runnerText-match'\$reportStatus = .*\$unavailableGroups.*''unavailable'''-and$runnerText-match'if \(\[string\]\$report\.status -ceq ''unavailable''\).*exit 2') 'installed report does not separate formal qualification from non-formal measurements'
Check ($trialText-match'host_surface=\$\(if\(\$installedMode\)\{''installed-desktop-path'''-and$runnerText-match"desktop\.host_surface -cne 'installed-desktop-path'"-and$groupProjection-match"host_surface[^\r\n]*installed-desktop-path"-and$reportProjection-match"host_surface[^\r\n]*installed-desktop-path") 'installed trial/group/report does not explicitly identify the installed Desktop surface'
Check ($runnerText-match'\$profileConfig -isnot \[Collections\.IDictionary\]'-and$runnerText-match'\$profileConfig\.status -ceq ''absent'''-and$runnerText-match'\$profileConfig\.status -ceq ''present'''-and$runnerText-match'\^sha256:\[0-9a-f\]\{64\}\$'-and$runnerText-match'Test-InstalledDesktopUserConfigBinding -Expected \$profileConfig -Actual \$record\.installed_desktop\.profile_config') 'installed profile_config shape or same-group binding consistency is not runner-enforced'
$trialSetStart=$runnerText.IndexOf('function Test-ReleaseHostTrialSet')
$trialSetEnd=$runnerText.IndexOf('function Get-SanitizedHostTrialDiagnostic',$trialSetStart)
$trialSetBlock=if($trialSetStart-ge0-and$trialSetEnd-gt$trialSetStart){$runnerText.Substring($trialSetStart,$trialSetEnd-$trialSetStart)}else{''}
$qualificationAggregateStart=$runnerText.IndexOf('$installedProfileConfig =')
$qualificationAggregateEnd=$runnerText.IndexOf('$passedGroups =',$qualificationAggregateStart)
$qualificationAggregateBlock=if($qualificationAggregateStart-ge0-and$qualificationAggregateEnd-gt$qualificationAggregateStart){$runnerText.Substring($qualificationAggregateStart,$qualificationAggregateEnd-$qualificationAggregateStart)}else{''}
Check ($runnerText-match'\$sourceInputs\[''installed_inputs''\]'-and$runnerText-match'install_digest=Get-HarnessFileDigest'-and$runnerText-match'uninstall_digest=Get-HarnessFileDigest'-and$runnerText-match'verification_digest=Get-HarnessFileDigest'-and$runnerText-match'protocol_digest=Get-HarnessFileDigest'-and$qualificationAggregateBlock-notmatch'rollout') 'installed qualification does not bind its exact producer inputs or still depends on rollout evidence'
Check ($text-notmatch '\$env:USERPROFILE = \[string\]\$savedEnvironment\[''USERPROFILE''\]') 'model invocation still restores the real user profile'
Check ($trialText-match'Initialize-HostWorkspaceBaseline'-and$trialText-match"core.hooksPath','NUL"-and$trialText-match'--force'-and$trialText-match'Get-HostWorkspaceChanges'-and$trialText-match'\$BaselineRevision'-and$trialText-match'--ignored'-and$trialText-match"ls-files','-v'"-and$trialText-match'__git_index_flag__/'-and$trialText-match'Test-HostWorkspaceChangePathsSafe'-and$trialText-match'Test-HostExactUtf8File') 'native workspace baseline/diff, index-flag, path-link, hook, or exact-byte verification is missing'
Check (Test-V1WriteBoundaryDataflow -TrialText $trialText -RunnerText $runnerText) 'v1 prompt, Trial classification, and independent runner do not share the exact fail-closed seven-path boundary'
$v1BoundaryMutations=@(
    $trialText.Replace('$writeBoundaryContract Return only schema-valid JSON.','Do not change another user file; harness-required task/runtime records are allowed. Return only schema-valid JSON.'),
    $trialText.Replace("`$v1RuntimeAllowlist = @('.assistant/运行时/当前任务.md','.assistant/运行时/恢复索引.md','.assistant/运行时/tasks/host-benchmark-fixed-workflow.md')","`$v1RuntimeAllowlist = @('.assistant/运行时/当前任务.md','.assistant/运行时/恢复索引.md','.assistant/运行时/tasks/host-benchmark-fixed-workflow.md','verification.txt')"),
    $trialText.Replace("if (`$Protocol -ceq 'v1' -and `$_ -cin `$v1AllowedWritePaths)","if (`$Protocol -ceq 'v1' -and `$_ -cin `$v1ArtifactAllowlist)"),
    $trialText.Replace("`$v1RuntimeAllowlist = @('.assistant/运行时/当前任务.md','.assistant/运行时/恢复索引.md','.assistant/运行时/tasks/host-benchmark-fixed-workflow.md')","`$v1RuntimeAllowlist = @('.assistant/运行时/当前任务.md','.assistant/运行时/恢复索引.md','.assistant/运行时/tasks/host-benchmark-fixed-workflow.md')`n        `$v1RuntimeAllowlist += @('verification.txt')")
)
foreach($mutation in $v1BoundaryMutations){Check ($mutation-cne$trialText-and-not(Test-V1WriteBoundaryDataflow -TrialText $mutation -RunnerText $runnerText)) 'v1 write-boundary verifier accepted a broad prompt, extra/duplicate path, or weakened Trial classification mutation'}
$runnerBoundaryMutation=$runnerText.Replace("`$allowed = @('src/value.txt') + `$artifactAllowlist + `$runtimeAllowlist","`$allowed = @('*')")
Check ($runnerBoundaryMutation-cne$runnerText-and-not(Test-V1WriteBoundaryDataflow -TrialText $trialText -RunnerText $runnerBoundaryMutation)) 'v1 write-boundary verifier accepted a widened independent runner allowlist'
$runnerOrderNeedle="            `$allowed = @('src/value.txt') + `$artifactAllowlist + `$runtimeAllowlist`n            if (@(`$changed | Where-Object { `$_ -cnotin `$allowed }).Count -ne 0 -or @(`$requiredArtifacts | Where-Object { `$_ -cnotin `$artifactChanges }).Count -ne 0 -or `$artifactChanges.Count -notin @(2,3) -or `$runtimeChanges.Count -ne 3) { return `$false }"
$runnerOrderLf=$runnerText-replace"`r`n?","`n"
foreach($runnerOrderInput in @($runnerOrderLf,($runnerOrderLf-replace"`n","`r`n"))){
    $runnerOrderSource=$runnerOrderInput-replace"`r`n?","`n"
    $runnerOrderMutation=$runnerOrderSource.Replace($runnerOrderNeedle,(@($runnerOrderNeedle-split"`n")[1]+"`n"+@($runnerOrderNeedle-split"`n")[0]))
    Check ($runnerOrderMutation-cne$runnerOrderSource-and-not(Test-V1WriteBoundaryDataflow -TrialText $trialText -RunnerText $runnerOrderMutation)) 'v1 write-boundary verifier accepted a runner consumer before its allowed-path producer'
}
Check ($text-match'Get-HostGitState -Root \$trialSourceRoot -IncludeIgnored'-and$text-match'Get-HostGitState -Root \$RepoRoot -IncludeIgnored'-and$text-match'v1ArtifactBoundaryPassed') 'ignored source or exact v1 artifact boundary is missing'
Check ($runnerText-match'function Test-HostTrialContract'-and$runnerText-match'function Test-HostRunnerTrialEvidence'-and$runnerText-match'Get-HostRunnerWorkspaceChanges'-and$runnerText-match"diff','--cached'"-and$runnerText-match"ls-files','-v'"-and$runnerText-match'__git_index_flag__/'-and$runnerText-match'Resolve-HarnessContainedPath'-and$runnerText-match'LinkType'-and$runnerText-match'runner_evidence_passed'-and$runnerText-match'runner_contract_failures'-and$runnerText-match'raw_trace_deleted'-and$runnerText-match'artifact_writes -ne 0'-and$runnerText-match'v1_stage_journal'-and$runnerText-match'RequireSourceBinding') 'Runner does not independently recheck trial and release contracts'
Check ($text-match'New-HostUnavailableTrial'-and$text-match'Get-SanitizedHostTrialDiagnostic'-and$text-match"return 'trial-exception'") 'trial exceptions are not converted to sanitized unavailable records'
Check ($runnerText-match"\.assistant\\运行时\\release-qualification"-and$runnerText-match'New-HarnessContainedDirectory'-and$runnerText-match'Resolve-HarnessContainedPath'-and$runnerText-match'Refusing to remove unsafe host benchmark scratch path') 'writable-root isolation or safe cleanup contract missing'
$protocolSetIndex=$trialText.IndexOf("if (`$Protocol -eq 'bare') { Remove-Item Env:HARNESS_PROTOCOL")
$installIndex=$trialText.IndexOf('$installOutput =')
$fixtureIndex=$trialText.IndexOf('Initialize-V1FixedWorkflowFixture -Workspace $workspace')
Check ($protocolSetIndex-ge0-and$installIndex-gt$protocolSetIndex-and$fixtureIndex-gt$protocolSetIndex) 'HARNESS_PROTOCOL is not isolated before installation and v1 fixture activation'
Check ($trialText-match"core\.longpaths','true"-and$trialText-match'git -c core\.longpaths=true clone') 'Windows long-path source/workspace Git contract is missing'
. $trial
$validSemanticTuples=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach($tuple in @(
    'completed|True|True|True|completed',
    'in_progress|False|False|False|stage_boundary',
    'in_progress|False|True|False|stage_boundary',
    'blocked|False|False|False|missing_decision',
    'blocked|False|True|False|missing_decision',
    'blocked|False|False|False|capability_block',
    'blocked|False|True|False|capability_block',
    'failed|False|False|False|execution_failed',
    'failed|False|True|False|verification_failed'
)){[void]$validSemanticTuples.Add($tuple)}
foreach($outcome in @('completed','in_progress','blocked','failed')){
    foreach($taskCompleted in @($false,$true)){
        foreach($verificationExecuted in @($false,$true)){
            foreach($verificationPassed in @($false,$true)){
                foreach($reason in @('completed','stage_boundary','missing_decision','capability_block','execution_failed','verification_failed')){
                    $tuple="$outcome|$taskCompleted|$verificationExecuted|$verificationPassed|$reason"
                    $observation=[ordered]@{schema_version='host-benchmark-observation/v1';outcome=$outcome;task_completed=$taskCompleted;verification_executed=$verificationExecuted;verification_passed=$verificationPassed;reason_code=$reason}
                    Check ((Test-HostObservationSemantics -Observation $observation)-eq$validSemanticTuples.Contains($tuple)) "host observation semantic tuple was misclassified: $tuple"
                }
            }
        }
    }
}
$contradictoryObservation=$contradictory|ConvertFrom-Json -AsHashtable -Depth 10
Check (-not(Test-HostObservationSemantics -Observation $contradictoryObservation)) 'logically contradictory completed observation accepted'
$invalidShape=$valid|ConvertFrom-Json -AsHashtable -Depth 10
$null=$invalidShape.Remove('reason_code')
Check (-not(Test-HostObservationSemantics -Observation $invalidShape)) 'host observation semantics accepted a missing field'
$invalidShape=$valid|ConvertFrom-Json -AsHashtable -Depth 10
$invalidShape.extra='unexpected'
Check (-not(Test-HostObservationSemantics -Observation $invalidShape)) 'host observation semantics accepted an extra field'
$invalidShape=$valid|ConvertFrom-Json -AsHashtable -Depth 10
$invalidShape.task_completed='true'
Check (-not(Test-HostObservationSemantics -Observation $invalidShape)) 'host observation semantics accepted a non-boolean field'
$invalidShape=$valid|ConvertFrom-Json -AsHashtable -Depth 10
$invalidShape.schema_version='host-benchmark-observation/v2'
Check (-not(Test-HostObservationSemantics -Observation $invalidShape)) 'host observation semantics accepted an unknown schema version'
$installFixture=Join-Path ([IO.Path]::GetTempPath()) ('host-install-integrity-'+[guid]::NewGuid().ToString('N'))
$savedFixtureCodexHome=[Environment]::GetEnvironmentVariable('CODEX_HOME',[EnvironmentVariableTarget]::Process)
try{
    $fixtureRepo=Join-Path $installFixture 'repo';$fixtureProfile=Join-Path $installFixture 'profile';$fixtureCodexHome=Join-Path $fixtureProfile '.codex';$fixtureWorkspace=Join-Path $installFixture 'workspace'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRepo 'tests'));[void][IO.Directory]::CreateDirectory($fixtureCodexHome);[void][IO.Directory]::CreateDirectory($fixtureWorkspace)
    $authPath=Join-Path $fixtureCodexHome 'auth.json';$configPath=Join-Path $fixtureCodexHome 'config.toml'
    [IO.File]::WriteAllText($authPath,'original-auth',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($configPath,'original=true',[Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('CODEX_HOME',$fixtureCodexHome,[EnvironmentVariableTarget]::Process)
    [IO.File]::WriteAllText((Join-Path $fixtureRepo 'install.ps1'),'param($WorkspaceRoot,$RepoRoot,$Preset);[IO.File]::WriteAllText((Join-Path $env:CODEX_HOME ''auth.json''),''changed-auth'');[IO.File]::WriteAllText((Join-Path $env:CODEX_HOME ''config.toml''),''changed=true'');exit 7',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRepo 'tests\verify-installation.ps1'),'param($WorkspaceRoot,$RepoRoot,$UserProfileRoot,$Scope);''STATUS: PASS''',[Text.UTF8Encoding]::new($false))
    $failedInstallIntegrity=$false
    try{[void](Invoke-InstalledDesktopInstall -CodexHome $fixtureCodexHome -Workspace $fixtureWorkspace -RepoRoot $fixtureRepo)}catch{$failedInstallIntegrity=$_.Exception.Message -match '^host-benchmark-installed-install-changed-(?:auth|config)$'}
    Check $failedInstallIntegrity 'failed install process mutation was classified as install-failed before immediate auth/config integrity comparison'
    [IO.File]::WriteAllText($authPath,'original-auth',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($configPath,'original=true',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRepo 'install.ps1'),'param($WorkspaceRoot,$RepoRoot,$Preset);exit 0',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRepo 'tests\verify-installation.ps1'),'param($WorkspaceRoot,$RepoRoot,$UserProfileRoot,$Scope);[IO.File]::WriteAllText((Join-Path $UserProfileRoot ''.codex\config.toml''),''changed=true'');''STATUS: PASS''',[Text.UTF8Encoding]::new($false))
    $verificationIntegrity=$false
    try{[void](Invoke-InstalledDesktopInstall -CodexHome $fixtureCodexHome -Workspace $fixtureWorkspace -RepoRoot $fixtureRepo)}catch{$verificationIntegrity=$_.Exception.Message -ceq 'host-benchmark-installed-verification-changed-config'}
    Check $verificationIntegrity 'verification process config mutation was not detected immediately after verification'
}finally{
    [Environment]::SetEnvironmentVariable('CODEX_HOME',$savedFixtureCodexHome,[EnvironmentVariableTarget]::Process)
    if(Test-Path -LiteralPath $installFixture){Remove-Item -LiteralPath $installFixture -Recurse -Force}
}
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$null,[ref]$null)
foreach($definition in @($runnerAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})){Invoke-Expression $definition.Extent.Text}
function New-InstalledContractRecord([string]$Protocol,[int]$Trial=1,[string]$ConfigStatus='present',[object]$ConfigDigest=('sha256:'+('1'*64))){
    $desktop=[ordered]@{benchmark_path='installed-desktop-path';host_surface='installed-desktop-path';user_config_mode='loaded';workspace_config_loaded=($Protocol-cne'bare');profile_config=[ordered]@{status=$ConfigStatus;digest=$ConfigDigest};protocol_environment='cleared';hook_trust='manual';hook_callability='manual'}
    if($Protocol-ceq'bare'){$desktop+=@{install_status='not-applicable';verification_status='not-applicable';cleanup_status='not-required';hook_installed='not-applicable';auth_unchanged=$null;workspace_protocol_config=$null;route_probe=$null}}
    else{
        $desktop+=@{install_status='pass';verification_status='pass';cleanup_status='passed';hook_installed='verified';auth_unchanged=$true}
        if($Protocol-ceq'v2'){
            $desktop.workspace_protocol_config=[ordered]@{status='pass';new_task_protocol='v2';preference_source='workspace-config';config_digest=('sha256:'+('2'*64))}
            $desktop.route_probe=[ordered]@{requested_protocol='v2';detected_protocol='new';selected_protocol='v2';preference_source='workspace-config';default_source='workspace-config';reason='workspace-v2-new-task';workspace_config_status='present';workspace_config_protocol='v2';runtime_default_status='not-read';artifact_kind='new-task'}
        }else{
            $desktop.workspace_protocol_config=$null
            $desktop.route_probe=[ordered]@{requested_protocol='auto';detected_protocol='v1';selected_protocol='v1';preference_source='workspace-config';default_source='existing-artifact';reason='existing-v1-plan';workspace_config_status='present';workspace_config_protocol='auto';runtime_default_status='not-read';artifact_kind='v1-plan'}
        }
    }
    return [ordered]@{trial=$Trial;runner_expected_trial=$Trial;runner_evidence_passed=$true;status='measured';completion_passed=$true;outcome='completed';reason_code='completed';workflow_completed=$true;total_duration_ms=1;unexpected_writes=0;raw_trace_deleted=$true;successful_request_sends=[ordered]@{status='measured';value=1;basis='codex-0.144.4-successful-websocket-send/v2'};host_turns=[ordered]@{status='measured';value=$(if($Protocol-ceq'v1'){5}else{1});basis='codex-jsonl-turn.started'};workflow_contract=$(if($Protocol-ceq'v1'){'confirmed-plan-to-done'}else{'new-task'});fresh_sessions=$(if($Protocol-ceq'v1'){5}else{1});v1_stage_journal=$(if($Protocol-ceq'v1'){@('PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')}else{@()});v1_target_journal=$(if($Protocol-ceq'v1'){@('alpha','alpha','beta','beta','beta')}else{@()});v1_validator_passed=$true;artifact_writes=$(if($Protocol-ceq'v1'){2}else{0});runtime_writes=$(if($Protocol-ceq'v1'){3}else{0});installed_desktop=$desktop;source_binding=[ordered]@{status='bound';revision='revision';commit_tree_oid='tree';verification='git-head-tree-clean/v1'}}
}
$validPresent=New-InstalledContractRecord -Protocol v2
$validAbsent=New-InstalledContractRecord -Protocol v2 -ConfigStatus absent -ConfigDigest $null
$invalidConfig=New-InstalledContractRecord -Protocol v2 -ConfigDigest $null
Check ((Test-HostTrialContract -Protocol v2 -Record $validPresent -ExpectedTrial 1 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path)-and(Test-HostTrialContract -Protocol v2 -Record $validAbsent -ExpectedTrial 1 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path)-and-not(Test-HostTrialContract -Protocol v2 -Record $invalidConfig -ExpectedTrial 1 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path)) 'runner accepts a malformed installed profile_config binding'
$wrongHostSurface=New-InstalledContractRecord -Protocol v2;$wrongHostSurface.installed_desktop.host_surface='codex-cli-host-equivalent'
Check (-not(Test-HostTrialContract -Protocol v2 -Record $wrongHostSurface -ExpectedTrial 1 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path)) 'runner accepts a CLI-host-equivalent installed trial as authoritative'
$contractSet=[ordered]@{};foreach($protocol in @('bare','v1','v2')){$contractSet[$protocol]=[ordered]@{trials=@(1..3|ForEach-Object{New-InstalledContractRecord -Protocol $protocol -Trial $_})}}
$consistentBindings=Test-ReleaseHostTrialSet -Records $contractSet -RequiredTrials 3 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path
$contractSet.v2.trials[2].installed_desktop.profile_config.digest='sha256:'+('3'*64)
Check ($consistentBindings-and-not(Test-ReleaseHostTrialSet -Records $contractSet -RequiredTrials 3 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path)) 'runner accepts mixed profile_config bindings in one installed group'
$routeSet=[ordered]@{};foreach($protocol in @('bare','v1','v2')){$routeSet[$protocol]=[ordered]@{trials=@(1..3|ForEach-Object{New-InstalledContractRecord -Protocol $protocol -Trial $_})}}
$consistentRoutes=Test-ReleaseHostTrialSet -Records $routeSet -RequiredTrials 3 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path
$routeSet.v2.trials[2].installed_desktop.route_probe.preference_source='HARNESS_PROTOCOL'
Check ($consistentRoutes-and-not(Test-ReleaseHostTrialSet -Records $routeSet -RequiredTrials 3 -SourceRevision revision -SourceCommitTree tree -BenchmarkPath installed-desktop-path)) 'runner accepts a process-only v2 selection in an installed group'
$eligibilityOutput=@(& pwsh -NoLogo -NoProfile -NonInteractive -File $runner -RepoRoot $RepoRoot -ValidateOnly -EligibilityReportPath 'forbidden.json' 2>&1|ForEach-Object{[string]$_});$eligibilityExit=$LASTEXITCODE
Check ($eligibilityExit-ne0-and($eligibilityOutput-join"`n")-match'EligibilityReportPath') 'installed producer still accepts EligibilityReportPath'
$output=@(& pwsh -NoLogo -NoProfile -NonInteractive -File $runner -RepoRoot $RepoRoot -ValidateOnly 2>&1|ForEach-Object{[string]$_});$exit=$LASTEXITCODE
Check ($exit-eq0-and($output-join"`n")-match'definition only; no model session executed') 'definition-only host runner failed or claimed a model run'
Write-Output "Host benchmark runner checks: $checks"
if($failures.Count){$failures|ForEach-Object{Write-Output "- FAIL: $_"};exit 1}
Write-Output "STATUS: PASS ($checks checks)"
