[CmdletBinding()]
param([string]$RepoRoot='', [string]$OutputRoot='')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot=[IO.Path]::GetTempPath() }
$root=Join-Path $OutputRoot ('hook-policy-search-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'work'
$homeRoot=Join-Path $root 'user'
$hooks=Join-Path $homeRoot 'hooks-memory'
foreach ($path in @($workspace,$hooks)) { [void][IO.Directory]::CreateDirectory($path) }
. (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1')
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.AdapterAction.psm1') -Force
$pwshPath=(Get-Process -Id $PID).Path
foreach ($name in @('pretooluse.ps1','codex-pretooluse-launcher.ps1')) {
    $text=[IO.File]::ReadAllText((Join-Path $RepoRoot "runtime-hooks/claude/$name")).Replace('{REPO_ROOT}',$RepoRoot).Replace('{PWSH_EXE}',$pwshPath).Replace('{CLAUDE_HOME}',$homeRoot)
    [IO.File]::WriteAllText((Join-Path $hooks $name),$text,[Text.UTF8Encoding]::new($true))
}
$marker='SYNTHETIC_POLICY_SEARCH_PRIVATE_MARKER'
$cases=@(
    @{name='literal-sql-search';command='rg --no-config -n -F -e "DROP DATABASE" -e "CREATE DATABASE" -e "DELETE FROM" before.sql';allow=$true},
    @{name='double-quoted-data';command='rg --no-config --fixed-strings -e "TRUNCATE" before.sql';allow=$true},
    @{name='static-regex-count';command='rg --no-config --count -e "(?i)^\s*(USE\s|CREATE DATABASE|DROP DATABASE)|\x60synthetic_lab\x60\." before.sql';allow=$true},
    @{name='static-keyword-count';command='rg --no-config --count -e "DROP DATABASE" before.sql';allow=$true},
    @{name='original-count-form';command='rg --count ''(?i)^\s*(USE\s|CREATE DATABASE|DROP DATABASE)|`synthetic_lab`\.'' before.sql';allow=$false;code='policy-requirement'},
    @{name='single-quoted-regex-count';command='rg --no-config --count -e ''(?i)^\s*(USE\s|CREATE DATABASE|DROP DATABASE)'' before.sql';allow=$false;code='policy-requirement'},
    @{name='count-backtick-substitution';command='rg --no-config --count -e "DROP `mysql`" before.sql';allow=$false;code='policy-requirement'},
    @{name='count-escaped-quote';command='rg --no-config --count -e "DROP\" --pre mysql before.sql';allow=$false;code='policy-requirement'},
    @{name='count-read-only-session';command='rg --no-config --count -e "(?i)^\s*(DROP DATABASE)" before.sql';allow=$false;readonly=$true;code='read-only'},
    @{name='direct-write-missing-environment';command='mysql -e "DELETE FROM synthetic"';allow=$false;mode='';code='policy-requirement'},
    @{name='production-write';command='mysql -e "DELETE FROM synthetic"';allow=$false;mode='production';code='policy-requirement'},
    @{name='compound-write';command='rg --no-config -F ''DROP'' before.sql; mysql -e "DELETE FROM synthetic"';allow=$false;code='policy-requirement'},
    @{name='pipeline';command='rg --no-config -F ''DROP'' before.sql | mysql';allow=$false;code='policy-requirement'},
    @{name='preprocessor';command='rg --no-config --pre mysql -F ''DROP'' before.sql';allow=$false;code='policy-requirement'},
    @{name='quoted-preprocessor';command='rg --no-config "--pre" mysql -F ''DROP'' before.sql';allow=$false;code='policy-requirement'},
    @{name='escaped-preprocessor';command='rg --no-config \--pre harmless DROP before.sql';allow=$false;code='policy-requirement'},
    @{name='escaped-hostname-command';command='rg --no-config \--hostname-bin harmless DROP before.sql';allow=$false;code='policy-requirement'},
    @{name='single-quote-option-injection';command='rg --no-config -F ''DROP --pre mysql'' before.sql';allow=$false;code='policy-requirement'},
    @{name='configuration-not-disabled';command='rg -F ''DROP'' before.sql';allow=$false;code='policy-requirement'},
    @{name='powershell-substitution';command='rg --no-config -F "$(mysql -e ''DELETE FROM synthetic'')" before.sql';allow=$false;code='policy-requirement'},
    @{name='bash-substitution';command='rg --no-config -F "`mysql -e ''DELETE FROM synthetic''`" before.sql';allow=$false;code='policy-requirement'},
    @{name='cmd-expansion';command='rg --no-config -F "%QUERY%DROP" before.sql';allow=$false;code='policy-requirement'},
    @{name='delayed-expansion';command='rg --no-config -F "!QUERY!DROP" before.sql';allow=$false;code='policy-requirement'},
    @{name='read-only-session';command='rg --no-config -F ''DROP'' before.sql';allow=$false;readonly=$true;code='read-only'},
    @{name='custom-overlay';command='rg --no-config -F ''DROP'' before.sql';allow=$false;overlay=$true;code='policy-requirement'},
    @{name='count-custom-overlay';command='rg --no-config --count -e "(?i)^\s*(DROP DATABASE)" before.sql';allow=$false;overlay=$true;code='policy-requirement'}
)
$saved=@{}
foreach ($key in @('DEV_HARNESS_WORKSPACE_ROOT','HARNESS_SESSION_MODE','HARNESS_ENVIRONMENT','HARNESS_TASK_ID','HARNESS_EXPECTED_VERSION','HARNESS_DRY_RUN')) {
    $saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process')
    [Environment]::SetEnvironmentVariable($key,$null,'Process')
}
$results=[Collections.Generic.List[object]]::new()
try {
    foreach ($case in $cases) {
        $environment=if($case.ContainsKey('mode')){[string]$case.mode}else{''}
        $sessionMode=if($case.ContainsKey('readonly')){'read-only'}else{'write'}
        [Environment]::SetEnvironmentVariable('HARNESS_ENVIRONMENT',$environment,'Process')
        [Environment]::SetEnvironmentVariable('HARNESS_SESSION_MODE',$sessionMode,'Process')
        $overlayPath=Join-Path $workspace '.assistant/policies/protected-actions.local.json'
        if ($case.ContainsKey('overlay')) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $overlayPath))
            $overlay=@{schema_version='protected-actions-overlay/v1';rules=@(@{id='synthetic-search-policy';match=@{command_regex='(?i)rg'};requires_profile='governed';requires_approval='none';requires_dry_run=$false;requires_independent_review=$false})}
            [IO.File]::WriteAllText($overlayPath,($overlay|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        }
        $directAllowed=$false
        $directError=''
        try {
            $response=Invoke-HarnessAdapterPreflightAction -RepoRoot $RepoRoot -WorkspaceRoot $workspace -ActionMode write -ActionKind shell -ShellText $case.command -SessionMode $sessionMode -Environment $environment
            $directAllowed=[bool]$response.body.allowed
        } catch { $directError=$_.Exception.Message }
        $payload=@{tool_name='Bash';permission_mode='default';cwd=$workspace;tool_input=@{command=$case.command};user_prompt=$marker}|ConvertTo-Json -Depth 8 -Compress
        $adapter=Invoke-HarnessKernelProcess -FilePath $pwshPath -WorkingDirectory $workspace -Arguments @('-NoProfile','-NonInteractive','-File',(Join-Path $hooks 'pretooluse.ps1')) -TimeoutMilliseconds 30000 -StandardInput $payload
        $launcher=Invoke-HarnessKernelProcess -FilePath $pwshPath -WorkingDirectory $workspace -Arguments @('-NoProfile','-NonInteractive','-File',(Join-Path $hooks 'codex-pretooluse-launcher.ps1')) -TimeoutMilliseconds 30000 -StandardInput $payload
        $passed=$adapter.Complete-and$launcher.Complete-and$directAllowed-eq$case.allow-and$launcher.ExitCode-eq0-and[string]::IsNullOrEmpty($launcher.StdErr)
        if ($case.allow) {
            $passed=$passed-and$adapter.ExitCode-eq0-and[string]::IsNullOrEmpty($adapter.StdErr)-and$adapter.StdOut.Trim()-ceq'{}'-and$launcher.StdOut.Trim()-ceq'{}'
        } else {
            $reason="Harness PreToolUse denied: $($case.code); stage=policy; action=shell"
            $decision=try{($launcher.StdOut|ConvertFrom-Json -AsHashtable).hookSpecificOutput}catch{$null}
            $passed=$passed-and$adapter.ExitCode-eq2-and[string]::IsNullOrEmpty($adapter.StdOut)-and$adapter.StdErr.Trim()-ceq"HARNESS_DENY:$($case.code);stage=policy;action=shell"-and$null-ne$decision-and$decision.permissionDecision-ceq'deny'-and$decision.permissionDecisionReason-ceq$reason
        }
        $passed=$passed-and-not($adapter.StdOut+$adapter.StdErr+$launcher.StdOut+$launcher.StdErr).Contains($marker)
        $results.Add([ordered]@{name=$case.name;passed=$passed;direct_allowed=$directAllowed;direct_error=$directError;adapter_exit=$adapter.ExitCode;adapter_stderr=$adapter.StdErr.Trim();launcher_stdout=$launcher.StdOut.Trim()})
    }
    $stateFiles=@(Get-ChildItem -LiteralPath $workspace -Recurse -File -Force | Where-Object { $_.FullName -cne $overlayPath })
    if ($stateFiles.Count) { throw 'Preflight regression created business or authorization state' }
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') }
}
$report=Join-Path $root 'result.json'
[IO.File]::WriteAllText($report,($results|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$failures=@($results|Where-Object passed -eq $false)
Write-Output ("Hook policy search: {0} pass / {1} fail" -f ($results.Count-$failures.Count),$failures.Count)
foreach ($failure in $failures) { Write-Output ("FAIL: {0}; {1}" -f $failure.name,$failure.adapter_stderr) }
Write-Output ('Report: '+$report)
if ($failures.Count) { exit 1 }
exit 0
