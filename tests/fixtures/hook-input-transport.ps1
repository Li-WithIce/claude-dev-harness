param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference='Stop'
$pwsh=(Get-Process -Id $PID).Path
$root=Join-Path $OutputRoot ('input-transport-'+[guid]::NewGuid().ToString('N'))
$hooks=Join-Path $root 'hooks'
$workspace=Join-Path $root 'workspace'
foreach($path in @($hooks,$workspace)){[void][IO.Directory]::CreateDirectory($path)}
# Core no longer protects auth paths; a workspace overlay keeps the protected-policy case covered.
[void][IO.Directory]::CreateDirectory((Join-Path $workspace '.assistant/policies'))
[IO.File]::WriteAllText((Join-Path $workspace '.assistant/policies/protected-actions.local.json'),'{"schema_version":"protected-actions-overlay/v1","rules":[{"id":"fixture-authorization-path","match":{"path_globs":["**/auth/**"]},"requires_profile":"governed","requires_approval":"none","requires_dry_run":false,"requires_independent_review":true}]}',[Text.UTF8Encoding]::new($false))
. (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1')
$results=[Collections.Generic.List[object]]::new()
$probe=@'
function Save-InputIdentity([string]$Phase,[string]$Text) {
    $bytes=[Text.Encoding]::UTF8.GetBytes($Text)
    [ordered]@{phase=$Phase;codepage=[Console]::InputEncoding.CodePage;characters=$Text.Length;bytes=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))}|ConvertTo-Json -Compress|Add-Content -LiteralPath '__OBS__' -Encoding utf8
}
'@
$cwd=$workspace.Replace('\','\\')
$ch=[string][char]0x4e2d
# These are fixed test packets, never reserialized historical Hook input.
$read='{"tool_name":"Bash","permission_mode":"default","tool_input":{"command":"Write-Output \"'+$ch+'\""},"cwd":"'+$cwd+'"}'
$mutation='{"tool_name":"apply_patch","permission_mode":"default","tool_input":{"command":"*** Begin Patch\n*** Add File: notes.txt\n+'+$ch+' \\path\\file \"quoted\"\n*** End Patch"},"cwd":"'+$cwd+'"}'
$protected=$mutation.Replace('notes.txt','auth/authorize.ps1')
$cases=@(
    @{name='chinese-escaped-quote';text=$read;allow=$true},
    @{name='utf8-bom';text=([string][char]0xfeff+$read);allow=$true},
    @{name='multiline-backslash-mutation';text=$mutation;allow=$true},
    @{name='malformed-json';text='{"tool_name":';allow=$false;adapter='HARNESS_DENY:unknown;stage=input;action=unknown';reason='Harness PreToolUse unclassified adapter exception; stage=input; action=unknown'},
    @{name='missing-tool';text='{}';allow=$false;adapter='HARNESS_DENY:input;stage=input;action=unknown';reason='Harness PreToolUse denied: input; stage=input; action=unknown'},
    @{name='non-string-tool';text='{"tool_name":42}';allow=$false;adapter='HARNESS_DENY:input;stage=input;action=unknown';reason='Harness PreToolUse denied: input; stage=input; action=unknown'},
    @{name='protected-policy';text=$protected;allow=$false;adapter='HARNESS_DENY:policy-requirement;stage=policy;action=apply_patch';reason='Harness PreToolUse denied: policy-requirement; stage=policy; action=apply_patch'}
)
foreach($case in $cases){
    $observation=Join-Path $root ($case.name+'.jsonl')
    $helper=$probe.Replace('__OBS__',$observation)
    $adapter=[IO.File]::ReadAllText((Join-Path $RepoRoot 'runtime-hooks/claude/pretooluse.ps1')).Replace('{REPO_ROOT}',$RepoRoot)
    $adapter=$adapter.Replace("`$stage = 'input'",($helper+[Environment]::NewLine+"`$stage = 'input'"))
    $adapter=$adapter.Replace('    $raw = [Console]::In.ReadToEnd()',('    $raw = [Console]::In.ReadToEnd()'+[Environment]::NewLine+"    Save-InputIdentity 'adapter' `$raw"))
    [IO.File]::WriteAllText((Join-Path $hooks 'pretooluse.ps1'),$adapter,[Text.UTF8Encoding]::new($true))
    $launcher=[IO.File]::ReadAllText((Join-Path $RepoRoot 'runtime-hooks/claude/codex-pretooluse-launcher.ps1')).Replace('{REPO_ROOT}',$RepoRoot).Replace('{PWSH_EXE}',$pwsh).Replace('{CLAUDE_HOME}',$root)
    $launcher=$launcher.Replace((Join-Path $root 'hooks-memory\pretooluse.ps1'),(Join-Path $hooks 'pretooluse.ps1'))
    $launcher=$launcher.Replace("`$launcherStage = 'startup'",($helper+[Environment]::NewLine+"`$launcherStage = 'startup'"))
    $launcher=$launcher.Replace('    $inputText = [Console]::In.ReadToEnd()',('    $inputText = [Console]::In.ReadToEnd()'+[Environment]::NewLine+"    Save-InputIdentity 'launcher' `$inputText"))
    $launcherPath=Join-Path $hooks 'launcher.ps1'
    [IO.File]::WriteAllText($launcherPath,$launcher,[Text.UTF8Encoding]::new($true))
    $r=Invoke-HarnessKernelProcess -FilePath $pwsh -WorkingDirectory $workspace -Arguments @('-NoProfile','-NonInteractive','-File',$launcherPath) -TimeoutMilliseconds 15000 -StandardInput $case.text
    $observed=@(Get-Content $observation|ForEach-Object{$_|ConvertFrom-Json})
    $expectedText=$case.text
    if($expectedText.Length-and[int]$expectedText[0]-eq0xfeff){$expectedText=$expectedText.Substring(1)}
    $expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($expectedText)))
    $originalHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($case.text)))
    $passed=$r.Complete-and$r.ExitCode-eq0-and[string]::IsNullOrEmpty($r.StdErr)-and$observed.Count-eq2-and$observed[0].codepage-eq65001-and$observed[1].codepage-eq65001-and$observed[0].sha256-ceq$originalHash-and$observed[1].sha256-ceq$expectedHash
    if($case.allow){$passed=$passed-and$r.StdOut.Trim()-ceq'{}'}else{
        $decision=$r.StdOut|ConvertFrom-Json
        $passed=$passed-and$decision.hookSpecificOutput.hookEventName-ceq'PreToolUse'-and$decision.hookSpecificOutput.permissionDecision-ceq'deny'-and$decision.hookSpecificOutput.permissionDecisionReason-ceq$case.reason
    }
    $direct=Invoke-HarnessKernelProcess -FilePath $pwsh -WorkingDirectory $workspace -Arguments @('-NoProfile','-NonInteractive','-File',(Join-Path $hooks 'pretooluse.ps1')) -TimeoutMilliseconds 15000 -StandardInput $case.text
    if($case.allow){$passed=$passed-and$direct.Complete-and$direct.ExitCode-eq0-and$direct.StdOut.Trim()-ceq'{}'-and[string]::IsNullOrEmpty($direct.StdErr)}else{$passed=$passed-and$direct.Complete-and$direct.ExitCode-eq2-and[string]::IsNullOrEmpty($direct.StdOut)-and$direct.StdErr.Trim()-ceq$case.adapter}
    $results.Add([ordered]@{case=$case.name;passed=$passed;complete=$r.Complete;exit_code=$r.ExitCode;adapter_exit_code=$direct.ExitCode;observations=$observed})
}
$report=Join-Path $root 'result.json'
$results|ConvertTo-Json -Depth 6|Set-Content $report
foreach($r in $results){Write-Output ('{0}: {1}' -f $r.case,$r.passed)}
Write-Output ('metadata: '+$report)
if((Test-Path (Join-Path $workspace 'notes.txt'))-or(Test-Path (Join-Path $workspace 'auth/authorize.ps1'))){throw 'Hook probe wrote a fixture target'}
if(@($results|Where-Object{-not$_.passed}).Count){exit 1}
exit 0
