[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$Condition,[string]$Label) {
    $script:checks++
    if ($Condition) { Write-Host "[PASS] $Label" } else { $script:failures.Add($Label); Write-Host "[FAIL] $Label" }
}
function Snapshot([string]$Root) {
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Root,$_.FullName)
        if ($_.PSIsContainer) { "D|$relative" } else { "F|$relative|$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
    } | Sort-Object) -join "`n"
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('host-diagnostics-'+[guid]::NewGuid().ToString('N'))
$workspace = Join-Path $root "work's sample"
$profile = Join-Path $root "user's profile"
$processProfile = Join-Path $root 'coordinator-profile'
$child = Join-Path $workspace 'src'
$sibling = Join-Path $root 'other-workspace'
$entry = Join-Path $workspace '.assistant/entry/task.ps1'
$hookHome = Join-Path $profile '.claude'
$launcher = Join-Path $hookHome 'hooks-memory/codex-pretooluse-launcher.ps1'
$adapter = Join-Path $hookHome 'hooks-memory/pretooluse.ps1'
$config = Join-Path $profile '.codex/hooks.json'
$observation = Join-Path $root 'observation.json'
$scriptPath = Join-Path $RepoRoot 'scripts/diagnose-harness-host.ps1'
$pwsh = (Get-Process -Id $PID).Path
$marker = 'SYNTHETIC_I03_PRIVATE_MARKER'
foreach ($dir in @($child,$sibling,$processProfile,(Split-Path $entry),(Split-Path $launcher),(Split-Path $config))) {
    [void][IO.Directory]::CreateDirectory($dir)
}
function Render-Hook([string]$Leaf,[string]$Target,[string]$Source=$RepoRoot) {
    $text = Read-FileUtf8 (Join-Path $RepoRoot "runtime-hooks/claude/$Leaf")
    foreach ($pair in @(@('{REPO_ROOT}',$Source),@('{PWSH_EXE}',$pwsh),@('{CLAUDE_HOME}',$hookHome))) {
        $text = $text.Replace($pair[0],$pair[1].Replace("'","''"))
    }
    Write-Utf8Bom $Target $text
}
function Write-Entry([string]$Source=$RepoRoot,[string]$TargetWorkspace=$workspace) {
    $text = "& '{0}' -RepoRoot '{1}' -WorkspaceRoot '{2}' @args" -f (Join-Path $Source 'scripts/task.ps1').Replace("'","''"),$Source.Replace("'","''"),$TargetWorkspace.Replace("'","''")
    Write-Utf8Bom $entry $text
}
function Diagnose($Record=$null,[string[]]$Extra=@()) {
    $arguments = @('-WorkspaceRoot',$workspace,'-RepoRoot',$RepoRoot,'-UserProfileRoot',$profile)
    if ($null -ne $Record) {
        [IO.File]::WriteAllText($observation,($Record | ConvertTo-Json -Depth 15))
        $arguments += @('-ObservationPath',$observation)
    }
    $beforeWorkspace = Snapshot $workspace
    $beforeProfile = Snapshot $profile
    # Keep PowerShell's own StartupProfileData cache in the coordinator profile;
    # the full observed profile and workspace remain immutable input fixtures.
    $process = Start-RepoProcess -UserProfile $processProfile -ScriptPath $scriptPath -Arguments ($arguments+$Extra) -WorkingDirectory $sibling
    try {
        if (-not $process.Process.WaitForExit(30000)) {
            $process.Process.Kill($true)
            throw 'Diagnostic process timed out; not a passing negative test'
        }
        $stdout = $process.StdOut.GetAwaiter().GetResult()
        $stderr = $process.StdErr.GetAwaiter().GetResult()
        Check ($stderr.Length -eq 0) 'diagnostic has no unstructured stderr'
        Check (-not ($stdout+$stderr).Contains($marker)) 'diagnostic omits unrelated sensitive text'
        $afterWorkspace = Snapshot $workspace
        $afterProfile = Snapshot $profile
        Check ($afterWorkspace -ceq $beforeWorkspace -and $afterProfile -ceq $beforeProfile) 'diagnostic preserves complete workspace and profile'
        if ($afterWorkspace -cne $beforeWorkspace -or $afterProfile -cne $beforeProfile) {
            Write-Host ('Changed fixture entries: '+(@(Compare-Object (($beforeWorkspace+"`n"+$beforeProfile) -split "`n") (($afterWorkspace+"`n"+$afterProfile) -split "`n") | ForEach-Object InputObject) -join '; '))
        }
        return @{Code=$process.Process.ExitCode;Report=($stdout | ConvertFrom-Json -AsHashtable);Text=$stdout}
    } finally { $process.Process.Dispose() }
}
try {
    Write-Entry
    Render-Hook 'codex-pretooluse-launcher.ps1' $launcher
    Render-Hook 'pretooluse.ps1' $adapter
    $command = ". '{0}'" -f $launcher.Replace("'","''")
    $configDocument = @{hooks=@{PreToolUse=@(@{matcher='*';hooks=@(@{type='command';command=$command})})};unrelated=$marker}
    [IO.File]::WriteAllText($config,($configDocument | ConvertTo-Json -Depth 10))

    $result = Diagnose
    Check ($result.Code -eq 0 -and $result.Report.hooks.Count -eq 1 -and $result.Report.hooks[0].source_aligned -and $result.Report.hooks[0].rendered_content_matches) 'entry and rendered downstream source identities agree'
    Check ($result.Report.coordinator_cwd -ieq $sibling -and $null -eq $result.Report.session.cwd) 'coordinator cwd never substitutes for session cwd'
    foreach ($dimension in @('loaded','hook_process_observed','host_tool_event_observed','decision_observed')) {
        Check ($null -eq $result.Report.evidence[$dimension].value) "no event leaves $dimension unknown"
    }
    Check ($result.Report.evidence.trusted.value -ceq 'unknown' -and $null -eq $result.Report.evidence.ids.hook_run_id -and -not $result.Report.authorizes_writes) 'configuration gives neither trust, fabricated host IDs nor authorization'

    $record = @{source_kind='host-record';source_reference='fixture-only-not-real-host';cwd=$child;threadId='copied-thread';turnId='copied-turn'}
    $result = Diagnose $record
    Check ($result.Code -eq 0 -and $result.Report.session.relation -ceq 'within-expected-workspace') 'legal child directory belongs to expected workspace'
    Check ($result.Report.evidence.ids.threadId -ceq 'copied-thread' -and $result.Report.evidence.ids.turnId -ceq 'copied-turn') 'native notification IDs are copied, not generated'
    $record.cwd=$sibling
    $result = Diagnose $record
    Check ($result.Code -eq 1 -and $result.Report.issues -contains 'observed-session-workspace-mismatch') 'recorded other workspace is an explicit mismatch'
    $record.cwd=$child
    $nestedEntry = Join-Path $child '.assistant/entry/task.ps1'
    [void][IO.Directory]::CreateDirectory((Split-Path $nestedEntry))
    Write-Utf8Bom $nestedEntry '# nested fixture marker'
    $result = Diagnose $record
    Check ($result.Code -eq 1 -and $result.Report.session.relation -ceq 'different-nested-workspace') 'nested installed workspace is not confused with ordinary child'
    [IO.File]::Delete($nestedEntry)

    Write-Entry $sibling
    $result = Diagnose
    Check ($result.Code -eq 1 -and $result.Report.issues -contains 'entry-source-mismatch') 'entry source mismatch is distinguished'
    Write-Entry $RepoRoot $sibling
    $result = Diagnose
    Check ($result.Code -eq 1 -and $result.Report.issues -contains 'entry-workspace-mismatch') 'entry root mismatch is distinguished'
    Write-Entry
    $foreignSource=Join-Path $root 'foreign-source'
    foreach ($leaf in @('Harness.RuntimeKernel.ps1','Harness.AdapterAction.psm1')) {
        Copy-RepoPathToFixture $RepoRoot $foreignSource "scripts/lib/$leaf"
    }
    Render-Hook 'codex-pretooluse-launcher.ps1' $launcher $foreignSource
    Render-Hook 'pretooluse.ps1' $adapter $foreignSource
    $result = Diagnose
    Check ($result.Code -eq 1 -and $result.Report.issues -contains 'hook-source-mismatch') 'equal downstream bytes at a different source remain a source mismatch'
    Render-Hook 'codex-pretooluse-launcher.ps1' $launcher
    Render-Hook 'pretooluse.ps1' $adapter
    $sentinel = Join-Path $workspace 'must-not-exist.txt'
    [IO.File]::AppendAllText($launcher,("`n[IO.File]::WriteAllText('{0}','executed')" -f $sentinel.Replace("'","''")))
    $result = Diagnose
    Check ($result.Code -eq 1 -and $result.Report.issues -contains 'hook-rendered-content-mismatch' -and -not (Test-Path $sentinel)) 'modified discovered script is inspected but never executed'
    Render-Hook 'codex-pretooluse-launcher.ps1' $launcher

    $record.cwd=$child
    $record.run=@{id='copied-hook-run';handlerType='command';status='completed';sourcePath=$config;entries=@(@{text=$marker});statusMessage=$marker}
    $record.tool_event=@{tool_name='apply_patch';tool_use_id='copied-tool-id';tool_input=@{command=$marker}}
    $record.hook_metadata=@{trustStatus='trusted';enabled=$true}
    $record.hookSpecificOutput=@{permissionDecision='deny';permissionDecisionReason='Harness PreToolUse denied: policy-requirement'}
    $result = Diagnose $record
    Check ($result.Code -eq 0 -and $result.Report.evidence.hook_process_observed.value -eq $true -and $result.Report.evidence.host_tool_event_observed.value -eq $true -and $result.Report.evidence.decision_observed.value -ceq 'deny' -and $result.Report.evidence.fixed_error_category -ceq 'policy-requirement') 'supplied fixture projection separates process, tool and exact fixed decision'
    Check ($result.Report.evidence.ids.tool_use_id -ceq 'copied-tool-id' -and $result.Report.evidence.ids.hook_run_id -ceq 'copied-hook-run' -and $null -eq $result.Report.evidence.loaded.value) 'native metadata does not invent loaded status or missing IDs'
    Check ($result.Report.evidence.correlation.observed_configuration_matches -eq $true -and $result.Report.evidence.correlation.harness_handler_attribution -ceq 'unknown' -and $result.Report.evidence.correlation.tool_to_hook_attribution -ceq 'unknown') 'shared config path does not prove Harness attribution or tool-decision linkage'
    $record.hookSpecificOutput.permissionDecisionReason='Harness PreToolUse denied: policy-requirement; stage=policy; action=file_mutation'
    $result = Diagnose $record
    Check ($result.Code -eq 0 -and $result.Report.evidence.fixed_error_category -ceq 'policy-requirement') 'new canonical reason preserves known host-record category classification'
    Check ($result.Report.evidence.correlation.harness_handler_attribution -ceq 'unknown' -and $result.Report.evidence.correlation.tool_to_hook_attribution -ceq 'unknown' -and -not $result.Report.authorizes_writes) 'new reason classification never authenticates the handler, decision linkage or writes'
    $record.hook_metadata.trustStatus='modified'
    $record.hook_metadata.enabled=$false
    $result = Diagnose $record
    Check ($result.Code -eq 1 -and $result.Report.evidence.trusted.value -ceq 'modified' -and $result.Report.evidence.enabled.value -eq $false) 'native modified trust and disabled status are explicit'
    $record.source_kind='synthetic-process'
    $result = Diagnose $record
    Check ($result.Code -eq 0 -and $result.Report.evidence.synthetic_process_observed -and $result.Report.evidence.synthetic_decision -ceq 'deny' -and $null -eq $result.Report.evidence.hook_process_observed.value -and $null -eq $result.Report.evidence.host_tool_event_observed.value -and $null -eq $result.Report.session.cwd) 'synthetic process receipt never becomes real host or session evidence'
    foreach ($code in @('input','permission-mode','workspace-binding','patch-path','patch-syntax','path-boundary','read-only','shell-form','policy-requirement','policy-unavailable','startup')) {
        foreach ($suffix in @('','; stage=unknown; action=unknown','; stage=target; action=apply_patch')) {
            $record.hookSpecificOutput.permissionDecisionReason='Harness PreToolUse denied: '+$code+$suffix
            $result = Diagnose $record
            Check ($result.Code -eq 0 -and $result.Report.evidence.fixed_error_category -ceq $code) 'legacy and contextual reason formats preserve the finite known category set'
            Check ($null -eq $result.Report.evidence.decision_observed.value -and $null -eq $result.Report.evidence.hook_process_observed.value -and $result.Report.evidence.synthetic_decision -ceq 'deny' -and $result.Report.evidence.correlation.harness_handler_attribution -ceq 'unknown') 'known synthetic reason does not upgrade observation provenance'
        }
    }
    foreach ($invalidReason in @(
        'Harness PreToolUse denied: unknown',
        'Harness PreToolUse denied: invented',
        "Harness PreToolUse denied: policy-requirement; stage=$marker; action=file_mutation",
        "Harness PreToolUse denied: policy-requirement; stage=policy; action=$marker",
        'Harness PreToolUse denied: policy-requirement; stage=policy',
        'Harness PreToolUse denied: policy-requirement; action=file_mutation; stage=policy',
        'Harness PreToolUse denied: policy-requirement; stage=policy; action=file_mutation; stage=policy',
        "Harness PreToolUse denied: policy-requirement; stage=policy; action=file_mutation; detail=$marker",
        "Harness PreToolUse denied: policy-requirement`n$marker",
        "Harness PreToolUse denied: policy-requirement`n",
        'Harness PreToolUse denied: policy-requirement; stage=Policy; action=file_mutation',
        'HARNESS_DENY:policy-requirement;stage=policy;action=file_mutation',
        'Harness PreToolUse unclassified adapter exception; stage=preflight; action=file_mutation',
        'Harness PreToolUse adapter returned invalid error output',
        'Harness PreToolUse launcher exception; stage=startup',
        12
    )) {
        $record.hookSpecificOutput.permissionDecisionReason=$invalidReason
        $result = Diagnose $record
        Check ($result.Code -eq 0 -and $result.Report.evidence.fixed_error_category -ceq 'unknown' -and $result.Report.evidence.synthetic_decision -ceq 'deny') 'unknown categories, invalid context and mixed content remain unclassified denials'
    }
    $record.hookSpecificOutput.permissionDecisionReason='Harness PreToolUse denied: policy-requirement; stage=policy; action=file_mutation'
    $record.hookSpecificOutput.permissionDecision='allow'
    $result = Diagnose $record
    Check ($result.Code -eq 0 -and $result.Report.evidence.fixed_error_category -ceq 'unknown' -and $result.Report.evidence.synthetic_decision -ceq 'allow') 'known denial text cannot override an explicit different decision'
    $record.hookSpecificOutput.permissionDecision='deny'
    $record.hookSpecificOutput.permissionDecisionReason=$marker
    $result = Diagnose $record
    Check ($result.Code -eq 0 -and $result.Report.evidence.fixed_error_category -ceq 'unknown' -and $result.Report.evidence.synthetic_decision -ceq 'deny') 'unknown denial stays unknown and denied without copying or hashing its text'
    $record.Remove('hookSpecificOutput')
    $result = Diagnose $record
    Check ($null -eq $result.Report.evidence.synthetic_decision) 'completed process alone gives no decision'

    $savePath=Join-Path $root 'saved-observation.json'
    $result = Diagnose -Extra @('-OutputPath',$savePath)
    Check ($result.Code -eq 0 -and $result.Report.save.succeeded -eq $true -and (Get-Content $savePath -Raw | ConvertFrom-Json).diagnostic_run_id -ceq $result.Report.diagnostic_run_id) 'explicit external CreateNew save preserves returned observation'
    $savedHash=(Get-FileHash $savePath).Hash
    $result = Diagnose -Extra @('-OutputPath',$savePath)
    Check ($result.Code -eq 3 -and $result.Report.assessment_exit_code -eq 0 -and $result.Report.save.succeeded -eq $false -and (Get-FileHash $savePath).Hash -ceq $savedHash) 'save failure preserves assessment and existing file without alternate write'
    $record.hookSpecificOutput=@{permissionDecision='deny';permissionDecisionReason=$marker}
    $result = Diagnose $record -Extra @('-OutputPath',$savePath)
    Check ($result.Code -eq 3 -and $result.Report.evidence.synthetic_decision -ceq 'deny' -and $result.Report.evidence.fixed_error_category -ceq 'unknown' -and (Get-FileHash $savePath).Hash -ceq $savedHash) 'save failure cannot change an unknown denial or rewrite prior evidence'
    $result = Diagnose -Extra @('-OutputPath',$sentinel)
    Check ($result.Code -eq 3 -and -not (Test-Path $sentinel)) 'workspace output is rejected without a write'
    $authPath=Join-Path $root 'auth.json'
    [IO.File]::WriteAllText($authPath,$marker)
    $result = Diagnose -Extra @('-ObservationPath',$authPath)
    Check ($result.Code -eq 1 -and $result.Report.issues -contains 'observation-unavailable-or-invalid') 'authentication file is excluded before parsing'
    $incompleteSource=Join-Path $root $marker
    [void][IO.Directory]::CreateDirectory($incompleteSource)
    $incompleteScript=Join-Path $incompleteSource 'diagnose-harness-host.ps1'
    [IO.File]::Copy($scriptPath,$incompleteScript)
    $scriptPath=$incompleteScript
    $result = Diagnose
    Check ($result.Code -eq 2 -and $result.Report.issues -contains 'diagnostic-input-or-source-unavailable') 'missing diagnostic startup dependency gives a fixed error without private path details'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Diagnostic fixture cleanup escaped test root' }
    [IO.Directory]::Delete($resolved,$true)
}
"Checks: $checks; failures: $($failures.Count)"
if ($failures.Count) { exit 1 }
exit 0
