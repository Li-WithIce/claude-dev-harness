#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$UserProfileRoot = $env:USERPROFILE,
    [string]$CodexHome = '',
    [string]$ObservationPath = '',
    [string]$OutputPath = '',
    [switch]$ProbeHostDetails
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$toolRoot=Split-Path -Parent $PSScriptRoot

function Value($Object,[string]$Name) {
    if($Object -is [Collections.IDictionary] -and $Object.Contains($Name)){return $Object[$Name]}
    return $null
}
function Identifier($InputValue) {
    if($InputValue -is [string] -and $InputValue -cmatch '^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,159}$'){return $InputValue}
    return $null
}
function In-Root([string]$Path,[string]$Root) {
    return $Path.Equals($Root,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function Local-Path($InputValue) {
    if($InputValue -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($InputValue) -or $InputValue.StartsWith('\\')){throw 'local-path-required'}
    return [IO.Path]::GetFullPath($InputValue)
}
function Safe-File([string]$Path) {
    if([IO.Path]::GetFileName($Path) -match '(?i)^(auth|credentials)(\.|$)'){throw 'sensitive-file-excluded'}
    return Resolve-HarnessContainedPath -WorkspaceRoot ([IO.Path]::GetPathRoot($Path)) -Path $Path -Label 'diagnostic file' -MustExist File
}
function File-Info([string]$Path) {
    $safe=Safe-File $Path
    return [ordered]@{path=$safe;sha256=(Get-HarnessFileSha256 -Path $safe);kind='file-identity-only'}
}
function Parse-Script([string]$Path) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Safe-File $Path),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'script-unparseable'}
    return $ast
}
function Literals($Ast) {
    @($Ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or ($n -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $n.NestedExpressions.Count -eq 0)},$true)|ForEach-Object Value)
}
function Script-References([string]$Command,[string]$Leaf) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Command,[ref]$tokens,[ref]$errors)
    if($errors.Count){return @()}
    return @(Literals $ast|Where-Object {[IO.Path]::IsPathFullyQualified($_) -and [IO.Path]::GetFileName($_) -ieq $Leaf}|Sort-Object -Unique)
}
function Assignment-Path($Ast,[string]$Name) {
    $assignments=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq $Name},$true))
    if($assignments.Count -ne 1){return $null}
    $values=@(Literals $assignments[0].Right|Where-Object {[IO.Path]::IsPathFullyQualified($_)})
    if($values.Count -eq 1){return Local-Path $values[0]}
    return $null
}
function Entry-Binding([string]$Path) {
    $ast=Parse-Script $Path
    $candidates=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.CommandElements[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and [IO.Path]::GetFileName($n.CommandElements[0].Value) -ieq 'task.ps1'},$true))
    if($candidates.Count -ne 1){throw 'entry-binding-unavailable'}
    $elements=$candidates[0].CommandElements;$bindings=[ordered]@{}
    for($i=1;$i -lt $elements.Count-1;$i++){
        if($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -in @('RepoRoot','WorkspaceRoot')){
            if($elements[$i+1] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $bindings.Contains($elements[$i].ParameterName)){throw 'entry-binding-unavailable'}
            $bindings[$elements[$i].ParameterName]=Local-Path $elements[$i+1].Value
        }
    }
    if(-not $bindings.Contains('RepoRoot') -or -not $bindings.Contains('WorkspaceRoot')){throw 'entry-binding-unavailable'}
    return [ordered]@{file=(File-Info $Path);repo_root=$bindings.RepoRoot;workspace_root=$bindings.WorkspaceRoot;script=(Local-Path $elements[0].Value);method='PowerShell AST literal binding; script not executed'}
}
function Template-Matches([string]$Template,[string]$Installed,[Collections.IDictionary]$Tokens) {
    # Same literal substitution contract as install.ps1 Get-RenderTokenMap:
    # PowerShell single-quoted tokens escape apostrophes; no discovered code runs.
    $expected=[IO.File]::ReadAllText((Safe-File $Template))
    foreach($key in $Tokens.Keys){$expected=$expected.Replace($key,$Tokens[$key].Replace("'","''"))}
    return $expected -ceq [IO.File]::ReadAllText((Safe-File $Installed))
}
function Dimension($State,[string]$Origin) { return [ordered]@{value=$State;origin=$Origin} }

$issues=[Collections.Generic.List[string]]::new()
$report=[ordered]@{diagnostic_run_id=('diagnostic-'+[guid]::NewGuid().ToString('N'));authorizes_writes=$false;observed_at=[DateTimeOffset]::UtcNow.ToString('o');coordinator_cwd=$PWD.Path;expected_workspace_root=$null;expected_repo_root=$null;session=$null;entry=$null;hooks=@();protocol=$null;cli=$null;evidence=$null;issues=@();save=[ordered]@{requested=(-not [string]::IsNullOrWhiteSpace($OutputPath));succeeded=$null}}
$exitCode=0
try {
    Import-Module (Join-Path $PSScriptRoot 'lib/Harness.HostCapabilities.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib/Harness.Protocol.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib/Harness.Hashing.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib/Harness.Path.psm1') -Force
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot (Local-Path $WorkspaceRoot)
    $RepoRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot (Local-Path $RepoRoot)
    $UserProfileRoot=Local-Path $UserProfileRoot
    $configOrigin='UserProfileRoot/.codex'
    if($CodexHome){$configOrigin='explicit CodexHome'}
    elseif(-not $PSBoundParameters.ContainsKey('UserProfileRoot') -and $env:CODEX_HOME){$CodexHome=$env:CODEX_HOME;$configOrigin='coordinator CODEX_HOME, not tested session environment'}
    else{$CodexHome=[IO.Path]::Combine($UserProfileRoot,'.codex')}
    $CodexHome=Local-Path $CodexHome
    $report['codex_home']=[ordered]@{path=$CodexHome;origin=$configOrigin}
    $report.expected_workspace_root=$WorkspaceRoot;$report.expected_repo_root=$RepoRoot
    try{
        $report.entry=Entry-Binding ([IO.Path]::Combine($WorkspaceRoot,'.assistant','entry','task.ps1'))
        if($report.entry.workspace_root -ine $WorkspaceRoot){$issues.Add('entry-workspace-mismatch')}
        if($report.entry.repo_root -ine $RepoRoot -or $report.entry.script -ine [IO.Path]::Combine($RepoRoot,'scripts','task.ps1')){$issues.Add('entry-source-mismatch')}
    }catch{$issues.Add('entry-binding-unavailable')}
    try{
        $p=Get-HarnessProtocolResolution -WorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot
        $report.protocol=[ordered]@{source='coordinator library query, not tested session execution';selected_protocol=$(if($p.selected_protocol -ceq 'v2'){'v2'}else{$null});new_task_admission=$(if($p.new_task_admission -cin @('enabled','existing','blocked','stopped')){$p.new_task_admission}else{'unknown'})}
    }catch{$issues.Add('protocol-unavailable')}
    $caps=Get-HarnessHostCapabilities -RepoRoot $toolRoot -ProbeHostDetails:$ProbeHostDetails
    $report.cli=[ordered]@{source='existing HostCapabilities; version refers only to resolved CLI';probed=[bool]$ProbeHostDetails;actual_version=$(if($caps.actual_version -cmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$'){$caps.actual_version}else{'unknown'});capabilities=$caps.capabilities;desktop_version='unknown'}
    foreach($configPath in @([IO.Path]::Combine($CodexHome,'hooks.json'),[IO.Path]::Combine($WorkspaceRoot,'.codex','hooks.json'))){
        if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){continue}
        try{
            $config=Get-Content -LiteralPath (Safe-File $configPath) -Raw|ConvertFrom-Json -AsHashtable
            $pre=Value (Value $config 'hooks') 'PreToolUse'
            foreach($section in @($pre)){foreach($hook in @(Value $section 'hooks')){
                if((Value $hook 'type') -cne 'command'){continue}
                $command=Value $hook 'command';if($command -isnot [string]){continue}
                foreach($launcherPath in @(Script-References $command 'codex-pretooluse-launcher.ps1')){
                    $binding=[ordered]@{configuration=$configPath;source_layer=$(if(In-Root $configPath $WorkspaceRoot){'project'}else{'user'});event='PreToolUse';reference_kind='literal-script-reference';launcher=$null;adapter=$null;runtime_kernel=$null;adapter_module=$null;powerShell=$null;source_aligned=$false;rendered_content_matches=$null}
                    try{
                        $launcherPath=Local-Path $launcherPath;$binding.launcher=File-Info $launcherPath;$ast=Parse-Script $launcherPath
                        $adapterPaths=@(Literals $ast|Where-Object {[IO.Path]::GetFileName($_) -ieq 'pretooluse.ps1' -and [IO.Path]::IsPathFullyQualified($_)}|Sort-Object -Unique)
                        $pwshPaths=@(Literals $ast|Where-Object {[IO.Path]::GetFileName($_) -ieq 'pwsh.exe' -and [IO.Path]::IsPathFullyQualified($_)}|Sort-Object -Unique)
                        if($adapterPaths.Count -ne 1){throw 'adapter-binding-unavailable'}
                        $binding.adapter=File-Info (Local-Path $adapterPaths[0]);$adapterAst=Parse-Script $adapterPaths[0]
                        $kernel=Assignment-Path $ast 'kernel';$module=Assignment-Path $adapterAst 'module'
                        if(-not $kernel -or -not $module -or [IO.Path]::GetFileName($kernel) -ine 'Harness.RuntimeKernel.ps1' -or [IO.Path]::GetFileName($module) -ine 'Harness.AdapterAction.psm1'){throw 'downstream-binding-unavailable'}
                        $binding.runtime_kernel=File-Info $kernel;$binding.adapter_module=File-Info $module
                        if($pwshPaths.Count -eq 1){$binding.powerShell=File-Info (Local-Path $pwshPaths[0])}
                        $binding.source_aligned=$kernel -ieq [IO.Path]::Combine($RepoRoot,'scripts','lib','Harness.RuntimeKernel.ps1') -and $module -ieq [IO.Path]::Combine($RepoRoot,'scripts','lib','Harness.AdapterAction.psm1')
                        if(-not $binding.source_aligned){$issues.Add('hook-source-mismatch')}
                        if($pwshPaths.Count -eq 1){
                            $tokens=@{'{REPO_ROOT}'=$RepoRoot;'{PWSH_EXE}'=$binding.powerShell.path;'{CLAUDE_HOME}'=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($binding.adapter.path))}
                            $binding.rendered_content_matches=(Template-Matches ([IO.Path]::Combine($RepoRoot,'runtime-hooks','claude','codex-pretooluse-launcher.ps1')) $launcherPath $tokens) -and (Template-Matches ([IO.Path]::Combine($RepoRoot,'runtime-hooks','claude','pretooluse.ps1')) $binding.adapter.path $tokens)
                            if(-not $binding.rendered_content_matches){$issues.Add('hook-rendered-content-mismatch')}
                        }else{$issues.Add('hook-powershell-binding-unavailable')}
                    }catch{$issues.Add('hook-binding-unavailable')}
                    $report.hooks+=@($binding)
                }
            }}
        }catch{$issues.Add('hook-configuration-unavailable')}
    }
    if($report.hooks.Count -eq 0){$issues.Add('no-harness-reference-in-observed-json-layers')}
    if($report.hooks.Count -gt 1){$issues.Add('multiple-harness-references-in-observed-json-layers')}
    $origin='none';$obs=$null
    if($ObservationPath){
        try{
            $obsPath=Safe-File (Local-Path $ObservationPath)
            if((Get-Item -LiteralPath $obsPath).Length -gt 65536){throw 'observation-too-large'}
            $obs=Get-Content -LiteralPath $obsPath -Raw|ConvertFrom-Json -AsHashtable -Depth 20
            if((Value $obs 'source_kind') -cnotin @('host-record','synthetic-process') -or -not(Identifier (Value $obs 'source_reference'))){throw 'observation-provenance-required'}
            $origin=Value $obs 'source_kind'
        }catch{$obs=$null;$issues.Add('observation-unavailable-or-invalid')}
    }
    $fromHost=$origin -ceq 'host-record'
    $sessionCwd=$null;$relation='unknown'
    if($fromHost -and (Value $obs 'cwd')){
        try{
            $sessionCwd=Local-Path (Value $obs 'cwd')
            $relation=if(In-Root $sessionCwd $WorkspaceRoot){'within-expected-workspace'}else{'different-workspace'}
            if($relation -ceq 'within-expected-workspace'){
                $cursor=$sessionCwd
                while($cursor -ine $WorkspaceRoot){
                    if(Test-Path -LiteralPath ([IO.Path]::Combine($cursor,'.assistant','entry','task.ps1')) -PathType Leaf){$relation='different-nested-workspace';break}
                    $cursor=[IO.Path]::GetDirectoryName($cursor)
                }
            }
            if($relation -cne 'within-expected-workspace'){$issues.Add('observed-session-workspace-mismatch')}
        }catch{$issues.Add('observed-session-cwd-invalid')}
    }
    $report.session=[ordered]@{cwd=$sessionCwd;relation=$relation;source=$(if($fromHost){'supplied host record; authenticity not independently established'}else{'unknown; coordinator cwd is not substituted'})}
    $run=Value $obs 'run';$metadata=Value $obs 'hook_metadata';$tool=Value $obs 'tool_event';$decision=Value $obs 'hookSpecificOutput'
    $categoriesText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../runtime-hooks/claude/codex-pretooluse-launcher.ps1'))
    $categoryMatch=[regex]::Match($categoriesText,'\\AHARNESS_DENY:\((?<codes>[a-z|\-]+)\)\\z')
    $categories=@($categoryMatch.Groups['codes'].Value.Split('|'))
    $reason=Value $decision 'permissionDecisionReason';$category='unknown'
    if($reason -is [string] -and $reason.StartsWith('Harness PreToolUse denied: ',[StringComparison]::Ordinal)){
        $candidate=$reason.Substring('Harness PreToolUse denied: '.Length)
        if($candidate -cin $categories){$category=$candidate}
    }
    $decisionValue=Value $decision 'permissionDecision'
    if($decisionValue -cnotin @('allow','deny')){$decisionValue=$null}
    if($decisionValue -cne 'deny'){$category='unknown'}
    $processSeen=(Identifier (Value $run 'id')) -and (Value $run 'handlerType') -ceq 'command' -and (Value $run 'status') -cin @('running','completed','failed','blocked','stopped')
    $toolName=Identifier (Value $tool 'tool_name')
    $loaded=Value $metadata 'loaded';if($loaded -isnot [bool]){$loaded=$null}
    $trusted=Value $metadata 'trustStatus';if($trusted -cnotin @('trusted','untrusted','managed','modified')){$trusted='unknown'}
    $enabled=Value $metadata 'enabled';if($enabled -isnot [bool]){$enabled=$null}
    $eventSource=$null;$configMatches=$null
    if(Value $run 'sourcePath'){
        try{
            $eventSource=Local-Path (Value $run 'sourcePath')
            $configMatches=@($report.hooks|Where-Object {$_.configuration -ieq $eventSource}).Count -gt 0
        }catch{$issues.Add('event-source-path-invalid')}
    }
    $report.evidence=[ordered]@{
        origin=$origin
        source_reference=(Identifier (Value $obs 'source_reference'))
        configured=(Dimension ($report.hooks.Count -gt 0) 'observed JSON configuration, not host loading')
        loaded=(Dimension $(if($fromHost){$loaded}else{$null}) $origin)
        trusted=(Dimension $(if($fromHost){$trusted}else{'unknown'}) $origin)
        enabled=(Dimension $(if($fromHost){$enabled}else{$null}) $origin)
        hook_process_observed=(Dimension $(if($fromHost -and $processSeen){$true}else{$null}) $origin)
        host_tool_event_observed=(Dimension $(if($fromHost -and $toolName){$true}else{$null}) $origin)
        decision_observed=(Dimension $(if($fromHost){$decisionValue}else{$null}) $origin)
        fixed_error_category=$category
        synthetic_process_observed=($origin -ceq 'synthetic-process' -and [bool]$processSeen)
        synthetic_decision=$(if($origin -ceq 'synthetic-process'){$decisionValue}else{$null})
        ids=[ordered]@{
            threadId=(Identifier (Value $obs 'threadId'))
            turnId=(Identifier (Value $obs 'turnId'))
            session_id=(Identifier (Value $obs 'session_id'))
            turn_id=(Identifier (Value $obs 'turn_id'))
            tool_use_id=(Identifier (Value $tool 'tool_use_id'))
            hook_run_id=(Identifier (Value $run 'id'))
        }
        tool_name=$toolName
        hook_event_name=$(if((Value $run 'eventName') -ceq 'PreToolUse'){'PreToolUse'}else{'unknown'})
        correlation=[ordered]@{
            hook_source_path=$eventSource
            observed_configuration_matches=$configMatches
            harness_handler_attribution='unknown'
            tool_to_hook_attribution='unknown'
            note='A shared sourcePath or adjacent records do not identify the executed handler or link a tool to its decision; review original host records'
        }
        limitations=@(
            'Supplied records are projections, not authenticated authorization'
            'No full commands, patches, stderr, transcripts or secret digests retained'
            'TOML, plugin and managed layers require the host hooks/list interface'
            'HostCapabilities is a repository declaration, not a live desktop API discovery'
            'CLI version does not establish desktop loading or version'
        )
    }
    if($fromHost -and ($enabled -eq $false -or $trusted -cin @('untrusted','modified'))){$issues.Add('reported-hook-disabled-or-untrusted')}
    if($issues.Count){$exitCode=1}
}catch{$issues.Add('diagnostic-input-or-source-unavailable');$exitCode=2}
$report.issues=@($issues|Select-Object -Unique)
$report['assessment_exit_code']=$exitCode
if($OutputPath){
    try{
        $out=Local-Path $OutputPath
        if((In-Root $out $WorkspaceRoot) -or (In-Root $out $toolRoot)){throw 'observation-output-must-be-external'}
        $parent=Resolve-HarnessWorkspaceRoot -WorkspaceRoot ([IO.Path]::GetDirectoryName($out))
        $out=Resolve-HarnessContainedPath -WorkspaceRoot $parent -Path $out -Label 'diagnostic output' -AllowMissing
        $report.save.succeeded=$true
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 20)+"`n")
        $stream=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }catch{$report.save.succeeded=$false;$report.save['error']='output-write-failed';$exitCode=3}
}
$report|ConvertTo-Json -Depth 20
exit $exitCode
