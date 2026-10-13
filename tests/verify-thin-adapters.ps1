[CmdletBinding()]
param([string]$RepoRoot='',[switch]$HookOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$script:Passes=[Collections.Generic.List[string]]::new()
$script:Failures=[Collections.Generic.List[string]]::new()

function Check($Condition,[string]$Pass,[string]$Fail){if($Condition){$script:Passes.Add($Pass)}else{$script:Failures.Add($Fail)}}
function Read-Text([string]$Path){return [IO.File]::ReadAllText((Join-Path $RepoRoot $Path),[Text.UTF8Encoding]::new($false,$true))}
function Has-Bom([string]$Path){$bytes=[IO.File]::ReadAllBytes((Join-Path $RepoRoot $Path));return $bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF}
function Test-Schema($Value,[string]$Schema){
    try{return Test-Json -Json ($Value|ConvertTo-Json -Depth 40 -Compress) -SchemaFile (Join-Path $RepoRoot $Schema) -ErrorAction Stop -WarningAction SilentlyContinue}
    catch{return $false}
}
function Get-IndexBlobSha256([string]$Path){
    $git=@(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$git;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-c','core.fsmonitor=false','-C',$RepoRoot,'show',(':'+$Path))){[void]$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(-not$process.Start()){throw "unable to start Git index hash: $Path"}
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $hash=[Security.Cryptography.SHA256]::Create()
        try{[byte[]]$digest=$hash.ComputeHash($process.StandardOutput.BaseStream)}finally{$hash.Dispose()}
        $process.WaitForExit();$stderr=$stderrTask.GetAwaiter().GetResult()
        if($process.ExitCode-ne0){throw "unable to hash Git index blob: $Path`: $($stderr.Trim())"}
        return 'sha256:'+[Convert]::ToHexString($digest).ToLowerInvariant()
    }finally{$process.Dispose()}
}

$powershellPaths=@(
    'runtime-hooks/claude/pretooluse.ps1',
    'runtime-hooks/core/pretooluse.ps1',
    'scripts/get-adapter-inventory.ps1',
    'scripts/harness-write-mcp.ps1',
    'scripts/invoke-harness-skill.ps1',
    'scripts/lib/Harness.AdapterAction.psm1',
    'scripts/lib/Harness.AdapterDelegation.psm1',
    'tests/verify-thin-adapters.ps1'
)
foreach($path in $powershellPaths){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $path),[ref]$tokens,[ref]$errors)
    Check (@($errors).Count-eq0) "$path parses" "$path parse failed"
    Check (Has-Bom $path) "$path has UTF-8 BOM" "$path lacks UTF-8 BOM"
}

$schemaPath='schemas/adapter-kernel-api.schema.json'
$base=[ordered]@{schema_version='adapter-kernel-api/v1';message_type='request';body=$null}
$validBodies=@(
    [ordered]@{operation='preflight_action';repo_root='repo';workspace_root='work';workspace_root_fallback='';permission_mode='default';session_mode='write';action_mode='write';action_kind='file_mutation';shell_text='';patch_text='';changed_paths=@('src/a.ps1');task_id='';expected_version=$null;environment='';dry_run=$false;user_instruction=''},
    [ordered]@{operation='controlled_write';repo_root='repo';workspace_root='work';environment='';target_path='src/a.txt';content='x';expected_current_sha256='missing';task_id='';expected_version=$null;execution_profile='';contract_path='';contract_digest='';approval_id='';dry_run=$null},
    [ordered]@{operation='prepare_delegation';repo_root='repo';workspace_root='work';task_id='adapter-task';stage='PLAN';skill='codex';tool='codex';tool_profile_id='';mode='readonly';payload_json='{"task":"review"}'},
    [ordered]@{operation='commit_delegation';delegation_id=('a'*32);succeeded=$true;artifact_base64='eA==';session_id='';diagnostics=@()}
)
$requestSchemasValid=$true
foreach($body in $validBodies){$base.body=$body;if(-not(Test-Schema $base $schemaPath)){$requestSchemasValid=$false}}
Check $requestSchemasValid 'all four adapter request bodies satisfy adapter-kernel-api/v1' 'a valid Adapter API request failed Schema validation'

$responses=@(
    [ordered]@{operation='preflight_action';allowed=$true;protected=$false;matched_rules=@();required_scopes=@();approval_id=$null;operation_identity=$null;protected_operation=$null},
    [ordered]@{operation='controlled_write';written=$true;dry_run=$false;path='src/a.txt';digest=('sha256:'+('a'*64));protected=$false;matched_rules=@();approval_id=$null;operation_identity=$null;protected_operation=$null},
    [ordered]@{operation='prepare_delegation';delegation_id=('b'*32);backend_script='skill.ps1';backend_output_path='out.tmp';backend_task='review';backend_workspace='work';backend_files=@();backend_session='';backend_model='';backend_reasoning='medium';backend_timeout_seconds=1800;backend_read_only=$true;warnings=@()},
    [ordered]@{operation='commit_delegation';result=[ordered]@{ok=$true;status='delegated';artifact_paths=@('artifact.md');next_stage_hint='';handoff='';errors=@()};warnings=@()}
)
$responseSchemasValid=$true
$base.message_type='response'
foreach($body in $responses){$base.body=$body;if(-not(Test-Schema $base $schemaPath)){$responseSchemasValid=$false}}
Check $responseSchemasValid 'all four adapter response bodies satisfy adapter-kernel-api/v1' 'a valid Adapter API response failed Schema validation'
$base.message_type='request';$base.body=$validBodies[0];$base.body.unknown='escape'
Check (-not(Test-Schema $base $schemaPath)) 'Adapter API rejects unknown request fields' 'Adapter API accepted an unknown request field'
$base.body.Remove('unknown');$base.body.operation='fifth_operation'
Check (-not(Test-Schema $base $schemaPath)) 'Adapter API rejects operations outside the exact four' 'Adapter API accepted a fifth operation'

$apiSchema=Read-Text $schemaPath|ConvertFrom-Json -Depth 100
$requestDefinitions=@('preflightRequest','controlledWriteRequest','prepareDelegationRequest','commitDelegationRequest')
$responseDefinitions=@('preflightResponse','controlledWriteResponse','prepareDelegationResponse','commitDelegationResponse')
$operations=@($requestDefinitions|ForEach-Object{$apiSchema.definitions.$_.properties.operation.enum[0]}|Sort-Object)
Check (($operations-join'|')-ceq'commit_delegation|controlled_write|preflight_action|prepare_delegation') 'Adapter API exposes exactly four logical operations' 'Adapter API operation set drifted'
Check (@($requestDefinitions+$responseDefinitions|Where-Object{$apiSchema.definitions.$_.additionalProperties-ne$false}).Count-eq0) 'all Adapter API request and response bodies reject unknown fields' 'an Adapter API body permits unknown fields'
$requestPropertyNames=@($requestDefinitions|ForEach-Object{$apiSchema.definitions.$_.properties.PSObject.Properties.Name}|Sort-Object -Unique)
$escapeFields=@('command','file','arguments','policy','policy_override','digest_algorithm','expected_source_digest')
Check (@($escapeFields|Where-Object{$requestPropertyNames-ccontains$_}).Count-eq0) 'Adapter API has no generic command, file, policy, or digest escape field' 'Adapter API exposes a generic authority escape field'

Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.AdapterAction.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.AdapterDelegation.psm1') -Force
$exports=@(Get-Command -Module Harness.AdapterAction,Harness.AdapterDelegation|Select-Object -ExpandProperty Name|Sort-Object)
$expectedExports=@('Invoke-HarnessAdapterCommitDelegation','Invoke-HarnessAdapterControlledWrite','Invoke-HarnessAdapterPreflightAction','Invoke-HarnessAdapterPrepareDelegation')
Check (@(Compare-Object $expectedExports $exports -CaseSensitive).Count-eq0) 'K1 exposes exactly one function per Adapter API operation' 'K1 Adapter API exports drifted'
$preflightParameters=(Get-Command Invoke-HarnessAdapterPreflightAction).Parameters.Keys
$controlledParameters=(Get-Command Invoke-HarnessAdapterControlledWrite).Parameters.Keys
Check ($preflightParameters-ccontains'ActionKind'-and$preflightParameters-ccontains'PatchText'-and(-not $preflightParameters.Contains('Policy'))) 'preflight_action owns explicit patch semantics without a Policy override' 'preflight_action signature is not explicit or exposes Policy'
Check ($controlledParameters-ccontains'Content'-and$controlledParameters-ccontains'ExpectedCurrentSha256'-and(-not $controlledParameters.Contains('ExpectedSourceDigest'))) 'controlled_write owns source digest calculation inside K1' 'controlled_write exposes source digest authority to A3'

$readPreflight = @{RepoRoot=$RepoRoot;WorkspaceRoot=$RepoRoot;SessionMode='read-only';ActionMode='read'}
foreach ($literalCommand in @(
    'rg -n ''apply_patch'' source.txt',
    'grep "apply_patch" source.txt',
    'Write-Output ''apply_patch''',
    'Get-Content ''apply_patch.md''',
    'echo apply_patch',
    'Select-String -Pattern ''tools\.apply_patch'' -Path source.txt',
    'rg --fixed-strings ''tools.apply_patch'' source.txt'
)) {
    try {
        $response = Invoke-HarnessAdapterPreflightAction @readPreflight -ActionKind shell -ShellText $literalCommand
        Check $response.body.allowed 'bounded literal search/output arguments do not imply a patch invocation' 'literal command was not allowed'
    } catch { Check $false '' "literal command was misclassified: $literalCommand" }
}

# Contract narrowed deliberately: retain the old positive vectors as restrictions,
# rather than claiming a dialect or deleting vectors to make the checks pass.
foreach ($restrictedLiteralCommand in @(
    'echo apply_patch | grep patch',
    'printf ''%s\n'' ''apply_patch''',
    '[regex]::Match($text, ''apply_patch'')',
    '[pscustomobject]@{tool=''tools.apply_patch''; note=''literal metadata''}',
    '$label = ''apply_patch''; Write-Output $label',
    'Write-Output "# apply_patch"',
    "# apply_patch is documentation`necho done",
    "<#`napply_patch is documentation`n#>`nWrite-Output done",
    'Write-Output <# apply_patch payload #> done',
    'echo ''apply_patch''; rg ''applypatch'' source.txt',
    'bash -c ''echo apply_patch''',
    'bash -c ''echo "safe; apply_patch"''',
    'pwsh -Command ''Write-Output apply_patch''',
    'pwsh -Command ''Write-Output "safe; apply_patch"''',
    'Invoke-Expression ''Write-Output apply_patch'''
)) {
    $restricted = $false
    try { $null = Invoke-HarnessAdapterPreflightAction @readPreflight -ActionKind shell -ShellText $restrictedLiteralCommand }
    catch { $restricted = $_.Exception.Message -like 'Bash shell-form*' -and $_.Exception.Data['harness_preflight_stage'] -ceq 'action-input' }
    Check $restricted 'unknown dialect does not prove comments, variables, methods or nested code to be data' "unproven form was allowed: $restrictedLiteralCommand"
}
$policyStillRuns = $false
try {
    $null = Invoke-HarnessAdapterPreflightAction -RepoRoot $RepoRoot -WorkspaceRoot $RepoRoot -SessionMode read-only -ActionMode write -ActionKind shell -ShellText 'rg ''apply_patch'' source.txt'
} catch { $policyStillRuns = $_.Exception.Message -ceq 'read-only session cannot invoke a write tool' }
Check $policyStillRuns 'literal keyword recognition still runs the original policy' 'literal-data recognition bypassed policy'
$absolutePatchFixture = Join-Path $RepoRoot 'tmp/adapter-command-fixture/apply_patch.exe'
foreach ($patchInvocation in @(
    'apply_patch payload', '& ''apply_patch'' payload', '. ''apply_patch.ps1''',
    ('& ''{0}'' payload' -f $absolutePatchFixture.Replace("'","''")), 'appl\y_patch payload',
    '"apply_patch" payload', '''apply_''patch payload',
    'echo safe; apply_patch payload', 'echo safe && apply_patch payload',
    'echo safe | apply_patch payload', '& { apply_patch payload }',
    'bash -c ''echo safe; apply_patch payload''',
    'pwsh -NoProfile -Command ''apply_patch payload''',
    'cmd /c ''apply_patch payload''', 'Invoke-Expression ''apply_patch payload''',
    'Write-Output $(apply_patch payload)', 'echo "$(apply_patch payload)"',
    'echo `apply_patch payload`', 'rg --pre apply_patch source.txt',
    'sudo -u fixture apply_patch payload', '$tool = ''apply_patch''; & $tool',
    '$tool=''apply_patch''; & $tool',
    '$tool=''apply_patch''; Invoke-Expression $tool',
    'tool=''apply_patch''; eval $tool',
    'tool=''apply_patch''; bash -c ''echo safe; $tool''',
    'source <(printf ''apply_patch payload'')',
    'echo ''apply_patch payload'' | bash',
    'Write-Output ''apply_patch payload'' | Invoke-Expression',
    '$result = apply_patch payload', '[pscustomobject]@{value=apply_patch payload}',
    '<# apply_patch is documentation #>; apply_patch payload',
    'echo `apply_patch payload`tail',
    'echo "%SHELL_VALUE%" apply_patch',
    'Write-Output ''literal; apply_patch''',
    'rg --pre=apply_patch source.txt'
)) {
    $shellDenied = $false
    try { $null = Invoke-HarnessAdapterPreflightAction @readPreflight -ActionKind shell -ShellText $patchInvocation }
    catch { $shellDenied = $_.Exception.Message -like 'Bash shell-form*' -and $_.Exception.Data['harness_preflight_stage'] -ceq 'action-input' }
    Check $shellDenied 'actual, nested, compound and evaluated shell patch invocations remain denied' "shell patch invocation escaped: $patchInvocation"
}
$patch = "*** Begin Patch`n*** Add File: tmp/tk07-adapter-shape.txt`n+x`n*** End Patch"
foreach ($case in @(
    @{ActionKind='shell';ShellText='echo harmless'},
    @{ActionKind='Shell';ShellText='echo harmless'},
    @{ActionKind='apply_patch';PatchText=$patch},
    @{ActionKind='APPLY_PATCH';PatchText=$patch},
    @{ActionKind='file_mutation';ChangedPaths=@('tmp/tk07-adapter-shape.txt')},
    @{ActionKind='File_Mutation';ChangedPaths=@('tmp/tk07-adapter-shape.txt')},
    @{ActionKind='normalized_action'},
    @{ActionKind='Normalized_Action'},
    @{}
)) {
    try {
        if ($case.ContainsKey('PatchText')) { $directPatchCase = $case }
        $response = Invoke-HarnessAdapterPreflightAction @readPreflight @case
        Check ($response.body.allowed -eq $true -and $response.body.protected -eq $false) 'valid preflight shape preserves case-insensitive routing and omitted ActionKind compatibility' 'valid preflight shape changed its read-only response'
    } catch { Check $false '' "valid preflight shape failed: $($_.Exception.Message)" }
}
foreach ($case in @(
    @{Input=@{ActionKind='shell'};Error='shell preflight action shape is invalid'},
    @{Input=@{ActionKind='Shell';ShellText=" `t"};Error='shell preflight action shape is invalid'},
    @{Input=@{ActionKind='Shell';ShellText='echo x';PatchText='x'};Error='shell preflight action shape is invalid'},
    @{Input=@{ActionKind='Shell';ShellText='echo x';ChangedPaths=@('tmp/x')};Error='shell preflight action shape is invalid'},
    @{Input=@{ActionKind='Shell';ShellText='apply_patch payload'};Error='Bash shell-form apply_patch is denied because Codex PreToolUse does not expose the effective tool workdir or environment identity'},
    @{Input=@{ActionKind='apply_patch'};Error='apply_patch preflight action shape is invalid'},
    @{Input=@{ActionKind='APPLY_PATCH';PatchText=$patch;ShellText='x'};Error='apply_patch preflight action shape is invalid'},
    @{Input=@{ActionKind='APPLY_PATCH';PatchText=$patch;ChangedPaths=@('tmp/x')};Error='apply_patch preflight action shape is invalid'},
    @{Input=@{ActionKind='APPLY_PATCH';PatchText='invalid patch'};Error='direct apply_patch input has an invalid patch envelope'},
    @{Input=@{ActionKind='File_Mutation'};Error='file mutation preflight action shape is invalid'},
    @{Input=@{ActionKind='File_Mutation';ChangedPaths=@('tmp/x');ShellText='x'};Error='file mutation preflight action shape is invalid'},
    @{Input=@{ActionKind='File_Mutation';ChangedPaths=@('tmp/x');PatchText='x'};Error='file mutation preflight action shape is invalid'},
    @{Input=@{ActionKind='File_Mutation';ChangedPaths=@(" `t")};Error='file mutation input is missing target path'},
    @{Input=@{ActionKind='Normalized_Action';PatchText='x'};Error='normalized preflight action must not carry patch_text'}
)) {
    $message = ''
    try { $inputArguments = $case.Input; $null = Invoke-HarnessAdapterPreflightAction @readPreflight @inputArguments }
    catch { $message = [string]$_.Exception.Message }
    Check ($message -ceq $case.Error) 'invalid preflight shape is denied before policy, including mixed-case ActionKind' "preflight shape guard changed: expected=[$($case.Error)] actual=[$message]"
}

# H02 local preflights never apply business patches.
$h02Root=Join-Path ([IO.Path]::GetTempPath()) ('h02-paths-'+[guid]::NewGuid().ToString('N'))
$h02Workspace=Join-Path $h02Root 'work';$h02Sibling=Join-Path $h02Root 'work-sibling'
[void][IO.Directory]::CreateDirectory((Join-Path $h02Workspace 'src/auth'))
[void][IO.Directory]::CreateDirectory($h02Sibling)
[IO.File]::WriteAllText((Join-Path $h02Workspace 'src/records.mjs'),'offline fixture')
function Invoke-H02Patch([string]$Patch,[hashtable]$Overrides=@{}) {
    $arguments=@{RepoRoot=$RepoRoot;WorkspaceRoot=$h02Workspace;WorkspaceRootFallback=$h02Workspace;SessionMode='write';ActionMode='write';ActionKind=$directPatchCase.ActionKind;PatchText=$Patch}
    foreach($key in $Overrides.Keys){$arguments[$key]=$Overrides[$key]}
    try{$response=Invoke-HarnessAdapterPreflightAction @arguments;return @{Allowed=$response.body.allowed;Error='';Body=$response.body}}
    catch{return @{Allowed=$false;Error=[string]$_.Exception.Message;Body=$null}}
}
function H02-Snapshot { @(Get-ChildItem $h02Root -Recurse -Force|Sort-Object FullName|ForEach-Object{if($_.PSIsContainer){'D|'+$_.FullName}else{'F|'+$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}}) }
try {
    $beforeH02=H02-Snapshot
    $relative="*** Begin Patch`n*** Update File: src/records.mjs`n@@`n-offline fixture`n+changed fixture`n*** Add File: src/records.test.mjs`n+offline test fixture`n*** End Patch"
    $absolute=$relative.Replace('src/records.mjs',(Join-Path $h02Workspace 'src/records.mjs')).Replace('src/records.test.mjs',(Join-Path $h02Workspace 'src/records.test.mjs'))
    foreach($candidate in @($relative,$relative.Replace('/','\'),$absolute,$absolute.Replace('\','/'))){
        $result=Invoke-H02Patch $candidate
        Check $result.Allowed 'H02 relative/absolute slash variants allow the same local Update + Add' "H02 local equivalent patch denied: $($result.Error)"
    }
    foreach($operation in @('Add File','Delete File')){
        $tail=if($operation -ceq 'Add File'){"`n+fixture"}else{''}
        foreach($target in @('src/records.mjs',(Join-Path $h02Workspace 'src/records.mjs'))){
            $result=Invoke-H02Patch ("*** Begin Patch`n*** ${operation}: $target$tail`n*** End Patch")
            Check $result.Allowed 'H02 Add/Delete relative and absolute targets agree' "H02 Add/Delete target denied: $($result.Error)"
        }
    }
    # Synthetic UNC components are test data only; never probe this share.
    $uncFixture = '\\{0}\{1}\{2}' -f 'server', 'share', 'file'
    Check (($uncFixture.Split([char]92) -join '|') -ceq '||server|share|file') 'H02 synthetic UNC preserves both leading slashes and all components' 'H02 synthetic UNC construction changed its shape'
    $badTargets=@((Join-Path $h02Sibling 'outside.txt'),(Join-Path $h02Root 'outside.txt'),'C:relative.txt','/rooted.txt','\rooted.txt',$uncFixture,'\\?\C:\file','src/../outside.txt','src/file:stream','src/file.','src//file','src/CON','src/NUL.txt')
    foreach($target in $badTargets){
        $result=Invoke-H02Patch ("*** Begin Patch`n*** Add File: $target`n+x`n*** End Patch")
        Check (-not $result.Allowed) 'H02 outside, sibling, ADS, device and ambiguous targets are rejected' 'H02 invalid target escaped boundary'
        if ($target -ceq $uncFixture) {
            Check ($result.Error -ceq 'direct patch target must be relative or a fully qualified Windows drive path') 'H02 synthetic UNC is rejected by the expected path guard' 'H02 synthetic UNC rejection was not the expected path error'
        }
    }
    foreach($target in @('src/auth/canary.txt',(Join-Path $h02Workspace 'src/auth/canary.txt'))){
        $result=Invoke-H02Patch ("*** Begin Patch`n*** Add File: $target`n+x`n*** End Patch")
        Check (-not $result.Allowed -and $result.Error -match 'protected write requires TaskId and ExpectedVersion') 'H02 protected policy requirements survive target representation' "H02 protected target lost policy classification: $($result.Error)"
    }
    foreach($overrides in @(@{SessionMode='read-only'},@{WorkspaceRoot='';WorkspaceRootFallback=''},@{WorkspaceRootFallback=$h02Sibling},@{WorkspaceRoot=''})){
        Check (-not (Invoke-H02Patch $relative $overrides).Allowed) 'H02 read-only, missing host cwd and conflicting bindings fail closed' 'H02 unbound or read-only patch was allowed'
    }
    Check (-not (Invoke-H02Patch ($relative.Replace('src/records.test.mjs',(Join-Path $h02Sibling 'outside.txt')))).Allowed) 'H02 bad second target rejects entire preflight' 'H02 ignored a bad second target'
    $move="*** Begin Patch`n*** Update File: src/records.mjs`n*** Move to: src/renamed.mjs`n@@`n-offline fixture`n+x`n*** End Patch"
    Check (Invoke-H02Patch $move).Allowed 'H02 local relative Move succeeds' 'H02 local relative Move denied'
    $absoluteMove=$move.Replace('src/records.mjs',(Join-Path $h02Workspace 'src/records.mjs')).Replace('src/renamed.mjs',(Join-Path $h02Workspace 'src/renamed.mjs'))
    Check (Invoke-H02Patch $absoluteMove).Allowed 'H02 local absolute Move succeeds' 'H02 local absolute Move denied'
    foreach($badMove in @($move.Replace('src/renamed.mjs',(Join-Path $h02Sibling 'escaped.mjs')),$move.Replace('src/records.mjs',(Join-Path $h02Sibling 'source.mjs')))){
        Check (-not (Invoke-H02Patch $badMove).Allowed) 'H02 Move source and destination enforce containment' 'H02 Move escaped containment'
    }
    $link=Join-Path $h02Workspace 'linked'
    New-Item -ItemType Junction -Path $link -Target $h02Sibling -ErrorAction Stop|Out-Null
    try{foreach($target in @('linked/a.txt',(Join-Path $link 'a.txt'))){Check (-not (Invoke-H02Patch ("*** Begin Patch`n*** Add File: $target`n+x`n*** End Patch")).Allowed) 'H02 reparse targets denied in both forms' 'H02 reparse target allowed'}}finally{[IO.Directory]::Delete($link)}
    Check (@(Compare-Object (H02-Snapshot) $beforeH02).Count -eq 0) 'H02 all preflights preserve fixture tree' 'H02 preflight wrote files or state'
} finally {
    $resolved=[IO.Path]::GetFullPath($h02Root);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'H02 cleanup escaped test root'}
    [IO.Directory]::Delete($resolved,$true)
}

# H02 rendered-hook fixtures exercise classification, never host trust or real writes.
. (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1')
$denyRoot=Join-Path ([IO.Path]::GetTempPath()) ('h02-deny-'+[guid]::NewGuid().ToString('N'))
$denyWorkspace=Join-Path $denyRoot 'work';$denyHome=Join-Path $denyRoot 'user'
[void][IO.Directory]::CreateDirectory($denyWorkspace)
[void][IO.Directory]::CreateDirectory((Join-Path $denyHome 'hooks-memory'))
$denyAdapter=Join-Path $denyHome 'hooks-memory/pretooluse.ps1'
$denyLauncher=Join-Path $denyRoot 'launcher.ps1'
$pwshPath=(Get-Process -Id $PID).Path
function Render-H02Hook([string]$Relative,[string]$Target,[string]$SourceRoot=$RepoRoot) {
    $text=Read-Text $Relative
    $text=$text.Replace('{REPO_ROOT}',$SourceRoot).Replace('{PWSH_EXE}',$pwshPath).Replace('{CLAUDE_HOME}',$denyHome)
    [IO.File]::WriteAllText($Target,$text,[Text.UTF8Encoding]::new($true))
}
function Run-H02Hook([string]$Script,[string]$InputJson){
    Invoke-HarnessKernelProcess -FilePath $pwshPath -WorkingDirectory $denyWorkspace -TimeoutMilliseconds 30000 -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$Script) -StandardInput $InputJson
}
try {
    Render-H02Hook 'runtime-hooks/claude/pretooluse.ps1' $denyAdapter
    Render-H02Hook 'runtime-hooks/claude/codex-pretooluse-launcher.ps1' $denyLauncher
    # A harmless witness uses explicit executables, not guessed Hook provenance.
    # Backticks escape characters in PowerShell but execute a substitution in Bash.
    # No business patch is executed by either witness.
    $dialectWitness = 'echo `printf marker`tail'
    $gitCommand = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $bashWitnessPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $gitCommand) '../bin/bash.exe'))
    $witnessReady = (Test-Path -LiteralPath $bashWitnessPath -PathType Leaf) -and [string]::IsNullOrEmpty($env:BASH_ENV)
    Check $witnessReady 'explicit Bash witness is available without an injected startup script' 'dialect witness unavailable; not counted as a pass'
    if ($witnessReady) {
        $psWitness = Invoke-HarnessKernelProcess -FilePath $pwshPath -WorkingDirectory $denyWorkspace -TimeoutMilliseconds 30000 -Arguments @('-NoProfile','-NonInteractive','-Command',$dialectWitness)
        $bashWitness = Invoke-HarnessKernelProcess -FilePath $bashWitnessPath -WorkingDirectory $denyWorkspace -TimeoutMilliseconds 30000 -Arguments @('--noprofile','--norc','-c',$dialectWitness)
        $expectedPowerShell = "printf`nmarker`t" + "ail`n"
        Check ($psWitness.Complete -and $psWitness.ExitCode -eq 0 -and $psWitness.StdErr.Length -eq 0 -and $psWitness.StdOut -ceq $expectedPowerShell) 'PowerShell witness treats backticks as escapes' 'PowerShell witness semantics differed'
        Check ($bashWitness.Complete -and $bashWitness.ExitCode -eq 0 -and $bashWitness.StdErr.Length -eq 0 -and $bashWitness.StdOut -ceq "markertail`n") 'the identical Bash text executes printf substitution' 'Bash witness semantics differed'
    }
    $marker='SYNTHETIC_H02_PRIVATE_MARKER'
    $basePayload=[ordered]@{tool_name='Write';permission_mode='default';cwd=$denyWorkspace;tool_input=[ordered]@{file_path='ordinary.txt';content=$marker}}
    foreach($case in @(
        @{Name='input';Change='input';Code='input';Stage='tool';Action='unknown'},
        @{Name='permission-mode';Change='permission';Code='permission-mode';Stage='tool';Action='unknown'},
        @{Name='missing-cwd';Change='cwd';Code='workspace-binding';Stage='workspace';Action='file_mutation'},
        @{Name='outside';Change='outside';Code='path-boundary';Stage='target';Action='file_mutation'},
        @{Name='protected';Change='protected';Code='policy-requirement';Stage='policy';Action='file_mutation'},
        @{Name='read-only';Change='readonly';Code='read-only';Stage='policy';Action='file_mutation'},
        @{Name='patch-syntax';Change='patchsyntax';Code='patch-syntax';Stage='action-input';Action='apply_patch'},
        @{Name='patch-path';Change='patchpath';Code='patch-path';Stage='action-input';Action='apply_patch'},
        @{Name='unknown';Change='unknown';Code='unknown';Stage='input';Action='unknown'}
    )){
        $payload=$basePayload|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
        switch($case.Change){
            input{$payload.Remove('tool_input')}
            permission{$payload.permission_mode=$marker}
            cwd{$payload.Remove('cwd')}
            outside{$payload.tool_input.file_path=Join-Path $denyRoot "$marker.txt"}
            protected{$payload.tool_input.file_path="auth/$marker.txt"}
            readonly{$env:HARNESS_SESSION_MODE='read-only'}
            patchsyntax{$payload.tool_name=$directPatchCase.ActionKind.ToLowerInvariant();$payload.tool_input=@{command=$marker}}
            patchpath{$payload.tool_name=$directPatchCase.ActionKind.ToLowerInvariant();$payload.tool_input=@{command="*** Begin Patch`n*** Add File: C:invalid`n+$marker`n*** End Patch"}}
        }
        $inputJson=if($case.Change -ceq 'unknown'){$marker}else{$payload|ConvertTo-Json -Depth 10 -Compress}
        try{
            $result=Run-H02Hook $denyAdapter $inputJson
            $launcherResult=Run-H02Hook $denyLauncher $inputJson
        }finally{Remove-Item Env:HARNESS_SESSION_MODE -ErrorAction SilentlyContinue}
        $expectedError = "HARNESS_DENY:$($case.Code);stage=$($case.Stage);action=$($case.Action)"
        Check ($result.Complete -and $result.ExitCode -eq 2 -and $result.StdOut.Length -eq 0 -and $result.StdErr.Trim() -ceq $expectedError) "H02 adapter reports finite $($case.Name) classification" "H02 adapter classification failed for $($case.Name)"
        Check (-not ($result.StdOut+$result.StdErr).Contains($marker)) 'H02 adapter errors do not disclose synthetic private content' 'H02 adapter error disclosed synthetic content'
        $launcherDecision=try{($launcherResult.StdOut|ConvertFrom-Json -AsHashtable).hookSpecificOutput}catch{$null}
        $expectedReason = $(if($case.Code -ceq 'unknown'){'Harness PreToolUse unclassified adapter exception'}else{"Harness PreToolUse denied: $($case.Code)"}) + "; stage=$($case.Stage); action=$($case.Action)"
        Check ($launcherResult.Complete -and $launcherResult.ExitCode -eq 0 -and $launcherResult.StdErr.Length -eq 0 -and $null -ne $launcherDecision -and $launcherDecision.permissionDecision -ceq 'deny' -and $launcherDecision.permissionDecisionReason -ceq $expectedReason) "I03 synthetic process chain carries $($case.Name) denial to host response format" "I03 launcher decision failed for $($case.Name)"
        Check (-not ($launcherResult.StdOut+$launcherResult.StdErr).Contains($marker)) 'I03 synthetic chain never exposes private marker' 'I03 synthetic chain disclosed private marker'
    }
    foreach($target in @('ordinary.txt',(Join-Path $denyWorkspace 'ordinary.txt'))){
        $payload=$basePayload|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
        $payload.tool_name=$directPatchCase.ActionKind.ToLowerInvariant()
        $payload.tool_input=@{command="*** Begin Patch`n*** Add File: $target`n+$marker`n*** End Patch"}
        $result=Run-H02Hook $denyLauncher ($payload|ConvertTo-Json -Depth 10 -Compress)
        Check ($result.Complete -and $result.ExitCode -eq 0 -and $result.StdErr.Length -eq 0 -and $result.StdOut.Trim() -ceq '{}') 'H02 rendered launcher accepts equivalent direct local targets' 'H02 rendered launcher rejected a local target'
    }
    foreach ($inputCase in @(
        @{Tool=12;Input=@{command='echo harmless'};Denied=$true},
        @{Tool='Bash';Input='echo harmless';Denied=$true},
        @{Tool='Bash';Input=@{cmd='echo harmless'};Denied=$true},
        @{Tool='apply_patch';Input=@{command='echo harmless'};Denied=$true},
        @{Tool='apply_patch';Input=@{input=$patch};Denied=$true},
        @{Tool='functions.exec';Input=@{command=$patch};Denied=$false},
        @{Tool='Bash';Input=@{command='rg ''apply_patch'' source.txt'};Denied=$false},
        @{Tool='Bash';Input=@{command='echo safe; apply_patch payload'};Denied=$true}
    )) {
        $payload = @{tool_name=$inputCase.Tool;cwd=$denyWorkspace;tool_input=$inputCase.Input}
        $inputResult = Run-H02Hook $denyLauncher ($payload | ConvertTo-Json -Depth 8 -Compress)
        $decision = $inputResult.StdOut | ConvertFrom-Json -AsHashtable
        $isDenied = $decision.Contains('hookSpecificOutput') -and $decision.hookSpecificOutput.permissionDecision -ceq 'deny'
        Check ($inputResult.Complete -and $inputResult.ExitCode -eq 0 -and $isDenied -eq $inputCase.Denied) 'host tool name and input shape follow the actual adapter contract' 'tool/input mismatch or unknown-wrapper handling regressed'
    }
    # Synthetic compatibility conditions only: current development handlers, explicit
    # parent cwd, one absolute Update target and controlled fallback. This is not a
    # replay of the field H04 installation, its unknown payload or its environment.
    $businessParent = Join-Path $denyRoot 'parent'
    $businessChild = Join-Path $businessParent 'energy-dispatch-service'
    $businessTarget = Join-Path $businessChild 'src/main/java/com/goldwind/ipark/base/screen/leida/LeidaScreenMock.java'
    $legacyEntry = Join-Path $businessChild '.assistant/entry/task.ps1'
    $protectedTarget = Join-Path $businessParent 'auth/fixture.txt'
    $outsideTarget = Join-Path $denyRoot 'outside-business.txt'
    foreach ($path in @($businessTarget,$protectedTarget,$outsideTarget,$legacyEntry)) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    }
    foreach ($path in @($businessTarget,$protectedTarget,$outsideTarget)) {
        [IO.File]::WriteAllText($path,'class LeidaScreenMock {}',[Text.UTF8Encoding]::new($false))
    }
    $legacyBinding = "throw 'synthetic-legacy-entry-must-not-run'`n& '{0}' -RepoRoot '{1}' -WorkspaceRoot '{2}' @args`n" -f
        (Join-Path $RepoRoot 'scripts/task.ps1').Replace("'","''"),$RepoRoot.Replace("'","''"),$businessChild.Replace("'","''")
    [IO.File]::WriteAllText($legacyEntry,$legacyBinding,[Text.UTF8Encoding]::new($false))
    $parentEntry = Join-Path $businessParent '.assistant/entry/task.ps1'
    $businessSnapshot = {
        @(Get-ChildItem -LiteralPath $businessParent -Recurse -Force | Sort-Object FullName | ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($businessParent,$_.FullName)
            if ($_.PSIsContainer) { 'D|'+$relative } else { 'F|'+$relative+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash }
        }) -join "`n"
    }
    $beforeBusiness = & $businessSnapshot
    Check (-not (Test-Path -LiteralPath $parentEntry) -and (Test-Path -LiteralPath $legacyEntry)) 'synthetic business parent has no entry while its child retains a legacy binding' 'business compatibility fixture does not match its declared entry conditions'
    $savedFallback = [Environment]::GetEnvironmentVariable('DEV_HARNESS_WORKSPACE_ROOT','Process')
    try {
        foreach ($scenario in @(
            @{Name='fallback-absent';Fallback=$null;Target=$businessTarget;Category='';Stage=''},
            @{Name='fallback-same';Fallback=$businessParent;Target=$businessTarget;Category='';Stage=''},
            @{Name='fallback-conflict';Fallback=$businessChild;Target=$businessTarget;Category='workspace-binding';Stage='workspace'},
            @{Name='protected';Fallback=$null;Target=$protectedTarget;Category='policy-requirement';Stage='policy'},
            @{Name='outside';Fallback=$null;Target=$outsideTarget;Category='path-boundary';Stage='target'},
            @{Name='invalid-command-type';Fallback=$null;Target=$businessTarget;Category='input';Stage='tool'}
        )) {
            [Environment]::SetEnvironmentVariable('DEV_HARNESS_WORKSPACE_ROOT',$scenario.Fallback,'Process')
            $absoluteTarget = ([string]$scenario.Target).Replace('\','/')
            $updatePatch = "*** Begin Patch`n*** Update File: $absoluteTarget`n@@`n-class LeidaScreenMock {}`n+class LeidaScreenMock { /* synthetic only */ }`n*** End Patch"
            $businessPayload = [ordered]@{tool_name='apply_patch';permission_mode='default';cwd=$businessParent;tool_input=[ordered]@{command=$updatePatch}}
            if ($scenario.Name -ceq 'invalid-command-type') { $businessPayload.tool_input.command = 12 }
            $businessJson = $businessPayload | ConvertTo-Json -Depth 6 -Compress
            $adapterResult = Run-H02Hook $denyAdapter $businessJson
            $launcherResult = Run-H02Hook $denyLauncher $businessJson
            if ([string]::IsNullOrEmpty($scenario.Category)) {
                Check ($adapterResult.Complete -and $adapterResult.ExitCode -eq 0 -and $adapterResult.StdErr.Length -eq 0 -and $adapterResult.StdOut.Trim() -ceq '{}') "synthetic $($scenario.Name) permits an ordinary absolute Update without installing the parent" "synthetic $($scenario.Name) adapter rejected a valid ordinary Update"
                Check ($launcherResult.Complete -and $launcherResult.ExitCode -eq 0 -and $launcherResult.StdErr.Length -eq 0 -and $launcherResult.StdOut.Trim() -ceq '{}') "synthetic $($scenario.Name) preserves the adapter allow result" "synthetic $($scenario.Name) launcher changed the allow result"
            } else {
                $expectedError = "HARNESS_DENY:$($scenario.Category);stage=$($scenario.Stage);action=apply_patch"
                Check ($adapterResult.Complete -and $adapterResult.ExitCode -eq 2 -and $adapterResult.StdOut.Length -eq 0 -and $adapterResult.StdErr.Trim() -ceq $expectedError) "synthetic $($scenario.Name) retains exact category, stage and action" "synthetic $($scenario.Name) adapter refusal context changed"
                $decision = try { ($launcherResult.StdOut | ConvertFrom-Json -AsHashtable).hookSpecificOutput } catch { $null }
                $expectedReason = "Harness PreToolUse denied: $($scenario.Category); stage=$($scenario.Stage); action=apply_patch"
                Check ($launcherResult.Complete -and $launcherResult.ExitCode -eq 0 -and $launcherResult.StdErr.Length -eq 0 -and $null -ne $decision -and $decision.permissionDecision -ceq 'deny' -and $decision.permissionDecisionReason -ceq $expectedReason) "synthetic $($scenario.Name) retains a finite launcher denial" "synthetic $($scenario.Name) launcher refusal context changed"
            }
            $actualCategory = [regex]::Match($adapterResult.StdErr.Trim(),'\AHARNESS_DENY:(?<code>[a-z-]+);stage=(?<stage>[a-z-]+);action=apply_patch\z')
            Write-Output ("[SYNTHETIC BUSINESS] {0}: adapter_exit={1}; launcher_exit={2}; category={3}; stage={4}; historical_replay=false" -f $scenario.Name,$adapterResult.ExitCode,$launcherResult.ExitCode,$actualCategory.Groups['code'].Value,$actualCategory.Groups['stage'].Value)
            Check ((& $businessSnapshot) -ceq $beforeBusiness) "synthetic $($scenario.Name) leaves every business fixture entry unchanged" "synthetic $($scenario.Name) applied a patch or changed entry/state"
        }
    } finally {
        [Environment]::SetEnvironmentVariable('DEV_HARNESS_WORKSPACE_ROOT',$savedFallback,'Process')
    }
    Check (-not (Test-Path -LiteralPath $parentEntry) -and -not (Test-Path -LiteralPath (Join-Path $businessParent '.assistant/runtime')) -and -not (Test-Path -LiteralPath (Join-Path $businessChild '.assistant/runtime'))) 'synthetic compatibility never installs v2 or creates task state to obtain an allow result' 'business preflight created an entry or task state'

    foreach($stderrText in @('HARNESS_DENY:path-boundary',"HARNESS_DENY:path-boundary`n$marker",$marker)){
        [IO.File]::WriteAllText($denyAdapter,('[Console]::Error.WriteLine('''+$stderrText.Replace("'","''")+'''); exit 2'),[Text.UTF8Encoding]::new($true))
        $result=Run-H02Hook $denyLauncher '{}'
        $reason=try{($result.StdOut|ConvertFrom-Json -AsHashtable).hookSpecificOutput.permissionDecisionReason}catch{''}
        $expected=if($stderrText -ceq 'HARNESS_DENY:path-boundary'){'Harness PreToolUse denied: path-boundary; stage=unknown; action=unknown'}else{'Harness PreToolUse adapter returned invalid error output'}
        Check ($result.Complete -and $result.ExitCode -eq 0 -and $result.StdErr.Length -eq 0 -and $reason -ceq $expected) 'H02 launcher only forwards an exact recognized fixed code' 'H02 launcher classification/unknown fallback failed'
        Check (-not ($result.StdOut+$result.StdErr).Contains($marker)) 'H02 launcher never forwards arbitrary stderr' 'H02 launcher leaked arbitrary stderr'
    }
    foreach ($invalidCase in @(
        @{Code=2;Out=$marker;Err='HARNESS_DENY:input;stage=input;action=unknown'},
        @{Code=1;Out='';Err='HARNESS_DENY:input;stage=input;action=unknown'},
        @{Code=0;Out='{}';Err=' '},
        @{Code=2;Out='';Err="HARNESS_DENY:unknown;stage=$marker;action=unknown"}
    )) {
        $fake = '[Console]::Out.Write(''' + $invalidCase.Out.Replace("'","''") + ''');[Console]::Error.Write(''' + $invalidCase.Err.Replace("'","''") + ''');exit ' + $invalidCase.Code
        [IO.File]::WriteAllText($denyAdapter,$fake,[Text.UTF8Encoding]::new($true))
        $result = Run-H02Hook $denyLauncher '{}'
        $reason = ($result.StdOut | ConvertFrom-Json -AsHashtable).hookSpecificOutput.permissionDecisionReason
        Check ($reason -ceq 'Harness PreToolUse adapter returned invalid error output' -and -not ($result.StdOut+$result.StdErr).Contains($marker)) 'invalid/mixed adapter results deny without forwarding synthetic secrets' 'invalid result was accepted, misclassified or leaked content'
    }
    $faultRoot = Join-Path $denyRoot 'fault-source'
    [void][IO.Directory]::CreateDirectory((Join-Path $faultRoot 'scripts/lib'))
    [IO.File]::WriteAllText((Join-Path $faultRoot 'scripts/lib/Harness.AdapterAction.psm1'),("function Invoke-HarnessAdapterPreflightAction { throw '$marker' }"),[Text.UTF8Encoding]::new($true))
    Render-H02Hook 'runtime-hooks/claude/pretooluse.ps1' $denyAdapter $faultRoot
    $result = Run-H02Hook $denyLauncher ($basePayload | ConvertTo-Json -Depth 8 -Compress)
    $reason = ($result.StdOut | ConvertFrom-Json -AsHashtable).hookSpecificOutput.permissionDecisionReason
    Check ($reason -ceq 'Harness PreToolUse unclassified adapter exception; stage=preflight; action=file_mutation' -and -not ($result.StdOut+$result.StdErr).Contains($marker)) 'unclassified preflight exception is distinguishable from input failure without private data' 'unclassified failure lost phase/action or leaked content'
    [IO.File]::WriteAllText((Join-Path $faultRoot 'scripts/lib/Harness.RuntimeKernel.ps1'),("throw '$marker'"),[Text.UTF8Encoding]::new($true))
    Render-H02Hook 'runtime-hooks/claude/codex-pretooluse-launcher.ps1' $denyLauncher $faultRoot
    $result = Run-H02Hook $denyLauncher '{}'
    $reason = ($result.StdOut | ConvertFrom-Json -AsHashtable).hookSpecificOutput.permissionDecisionReason
    Check ($reason -ceq 'Harness PreToolUse launcher exception; stage=startup' -and -not ($result.StdOut+$result.StdErr).Contains($marker)) 'launcher startup exception is separately classified without private paths' 'launcher startup exception classification or redaction failed'
    Render-H02Hook 'runtime-hooks/claude/codex-pretooluse-launcher.ps1' $denyLauncher (Join-Path $denyRoot $marker)
    $result=Run-H02Hook $denyLauncher '{}'
    $startupDecision=try{($result.StdOut|ConvertFrom-Json -AsHashtable).hookSpecificOutput}catch{$null}
    Check ($result.Complete -and $result.ExitCode -eq 0 -and $result.StdErr.Length -eq 0 -and $null -ne $startupDecision -and $startupDecision.permissionDecision -ceq 'deny' -and $startupDecision.permissionDecisionReason -ceq 'Harness PreToolUse launcher startup dependency unavailable' -and -not $result.StdOut.Contains($marker)) 'H02 missing startup dependency denies without private paths' 'H02 startup rejection was not sanitized'
    Check (@(Get-ChildItem $denyWorkspace -Recurse -Force).Count -eq 0) 'H02 rendered hook fixtures never apply patches or create state' 'H02 hook fixture wrote business or runtime files'
} finally {
    $resolved=[IO.Path]::GetFullPath($denyRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'H02 cleanup outside test root'}
    [IO.Directory]::Delete($resolved,$true)
}

$classification=Read-Text 'kernel-component-classification.json'|ConvertFrom-Json -Depth 100
$a3=@($classification.components|Where-Object layer -CEQ 'a3-adapter')
if ($HookOnly) {
    foreach ($pass in $script:Passes) { Write-Output "[PASS] $pass" }
    foreach ($failure in $script:Failures) { Write-Output "[FAIL] $failure" }
    if ($script:Failures.Count) { exit 1 }
    Write-Output "STATUS: PASS ($($script:Passes.Count) Hook checks)"
    exit 0
}
$expectedA3=@('runtime-hooks/claude/codex-pretooluse-launcher.ps1','runtime-hooks/claude/pretooluse.ps1','runtime-hooks/claude/stop.js','runtime-hooks/claude/userpromptsubmit.js','runtime-hooks/claude/workspace-resolver.js','scripts/harness-write-mcp.ps1','scripts/invoke-harness-skill-dispatcher.ps1','scripts/invoke-harness-skill-supervisor.ps1','scripts/invoke-harness-skill.ps1')|Sort-Object
Check ($a3.Count-eq9-and(@($a3.path|Sort-Object)-join'|')-ceq($expectedA3-join'|')) 'classification binds the exact current nine A3 paths' 'A3 classification is missing, extra, or duplicated'
$mcpText=Read-Text 'scripts/harness-write-mcp.ps1'
$hookText=Read-Text 'runtime-hooks/claude/pretooluse.ps1'
$skillText=Read-Text 'scripts/invoke-harness-skill.ps1'
Check ($mcpText-match'Harness\.AdapterAction'-and$mcpText-notmatch'Harness\.(?:Hashing|ControlledWrite|ProtectedAction)'-and$mcpText-notmatch'Get-HarnessUtf8TextSha256') 'MCP A3 calls only controlled_write and computes no trust digest' 'MCP A3 retains digest or lower-K1 authority'
Check ($hookText-match'Invoke-HarnessAdapterPreflightAction'-and$hookText-notmatch'function\s+(?:Get-ApplyPatchChangedPaths|Assert-ApplyPatchRelativePath)') 'Hook A3 delegates patch and path validation to preflight_action' 'Hook A3 still owns patch or path policy'
Check ($skillText-match'Invoke-HarnessAdapterPrepareDelegation'-and$skillText-match'Invoke-HarnessAdapterCommitDelegation'-and$skillText-notmatch'lite-artifact-parser|Enter-LitePlanMutex|Write-LiteUtf8BomAtomic|docs[\\/]tasks') 'skill A3 retains process bridging but no plan, artifact, or trace authority' 'skill A3 still mutates governed task artifacts directly'

$inventoryPath=Join-Path $RepoRoot 'adapter-inventory.json'
$inventory=Read-Text 'adapter-inventory.json'|ConvertFrom-Json -AsHashtable -Depth 100
Check (Test-Json -Json (Read-Text 'adapter-inventory.json') -SchemaFile (Join-Path $RepoRoot 'schemas/adapter-inventory.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue) 'adapter-inventory/v1 satisfies its strict Schema' 'adapter-inventory/v1 failed Schema validation'
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.CanonicalJson.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.Hashing.psm1') -Force
$body=[ordered]@{}
foreach($key in @('schema_version','generator_contract_version','source_basis','classification','metric_contract','adapters','totals','digest_algorithm')){$body[$key]=$inventory[$key]}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($body|ConvertTo-Json -Depth 30 -Compress))
$actualInventoryDigest=Get-HarnessCanonicalJsonSha256 -JsonBytes $bytes
Check ([string]$inventory.inventory_digest-ceq$actualInventoryDigest-and[string]$inventory.digest_algorithm-ceq'canonical-json/v1') 'Adapter inventory digest is canonical-json/v1 over its exact body' 'Adapter inventory digest binding is stale'
$inventoryPaths=@($inventory.adapters|ForEach-Object{[string]$_.path}|Sort-Object)
$rawDigestsValid=$true
foreach($entry in $inventory.adapters){if([string]$entry.raw_sha256-cne (Get-IndexBlobSha256 -Path ([string]$entry.path))){$rawDigestsValid=$false}}
$classificationDigestValid=[string]$inventory.classification.sha256-ceq(Get-IndexBlobSha256 -Path ([string]$inventory.classification.path))
Check (($inventoryPaths-join'|')-ceq($expectedA3-join'|')-and$rawDigestsValid-and$classificationDigestValid-and[string]$inventory.source_basis-ceq'git-index-blob/v1') 'Adapter inventory binds exact Git index blobs for classification and A3 sources' 'Adapter inventory path, source basis, or index blob digest binding is stale'
Check ([int]$inventory.totals.adapter_count-eq9-and[int]$inventory.totals.maximum_adapter_executable_loc-lt200-and[int]$inventory.totals.threshold_breaches-eq0) 'all nine Adapters are below 200 executable LOC' 'an Adapter LOC threshold is breached'
$beforeHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash
$beforeWrite=(Get-Item -LiteralPath $inventoryPath).LastWriteTimeUtc
$checkOutput=@(& pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/get-adapter-inventory.ps1') -RepoRoot $RepoRoot -Check 2>&1|ForEach-Object{[string]$_})
$checkExit=$LASTEXITCODE
Check ($checkExit-eq0-and$beforeHash-ceq(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash-and$beforeWrite-eq(Get-Item -LiteralPath $inventoryPath).LastWriteTimeUtc) 'Adapter inventory Check is deterministic and zero-write' "Adapter inventory Check failed or wrote output: $($checkOutput-join' | ')"

$moduleV1=Read-Text 'schemas/module-manifest-v1.schema.json'|ConvertFrom-Json -Depth 100
Check (($moduleV1.properties.kind.enum-join'|')-ceq'capability') 'harness-module/v1 remains capability-only' 'TK-05 broadened harness-module/v1 beyond capability packages'
$tcb=Read-Text 'kernel-tcb-inventory.json'|ConvertFrom-Json -Depth 100
Check ([int]$tcb.totals.runtime_executable_loc-lt3392-and@($tcb.unresolved_dependencies).Count-eq0) 'Runtime TCB stays below the 3392 multi-workspace candidate bound with zero unresolved dependencies' 'Runtime TCB budget or dependency closure is invalid'

foreach($pass in $script:Passes){Write-Output "[PASS] $pass"}
if($script:Failures.Count){foreach($failure in $script:Failures){Write-Output "[FAIL] $failure"};exit 1}
Write-Output "STATUS: PASS ($($script:Passes.Count) checks)"
