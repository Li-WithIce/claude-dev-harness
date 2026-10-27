[CmdletBinding()]
param([string]$RepoRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('harness-context-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $scratch 'project'
$sessionHome = Join-Path $scratch 'codex'
$script:checks = 0
function Check([bool]$Condition,[string]$Message) {
    if (!$Condition) { throw $Message }
    $script:checks++
    Write-Host "PASS: $Message"
}
function Write-Source([string]$Relative,[string]$Text) {
    $path = Join-Path $scratch $Relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($false))
}
function Snapshot {
    return (@(Get-ChildItem -LiteralPath $scratch -Force -Recurse | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { 'D|' + $_.FullName } else { $_.FullName + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash }
    }) -join "`n")
}
function Invoke-Context([string[]]$Arguments,[switch]$Fails,[string]$ScriptPath = (Join-Path $RepoRoot 'scripts/context.ps1')) {
    $child = Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $ScriptPath -WorkingDirectory $workspace -Arguments ($Arguments + @('-WorkspaceRoot',$workspace,'-CodexHome',$sessionHome))
    try {
        if (!$child.Process.WaitForExit(30000)) { $child.Process.Kill($true); throw 'Context test timeout' }
        $output = $child.StdOut.GetAwaiter().GetResult()
        $errorText = $child.StdErr.GetAwaiter().GetResult()
        if ($Fails) { Check ($child.Process.ExitCode -ne 0) 'invalid input fails explicitly'; return $errorText }
        if ($child.Process.ExitCode -ne 0) { throw $errorText }
        return ($output | ConvertFrom-Json -AsHashtable)
    } finally { $child.Process.Dispose() }
}
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $workspace '.git'))
    Write-Source 'project/.gitignore' "ignored.md`nAGENTS.md`n"
    Write-Source 'project/AGENTS.md' '# 最小实现规范 internal agreement'
    Write-Source 'project/ignored.md' 'IgnoredCanary'
    Write-Source 'project/docs/current.md' '# 当前规范 current endpoint agreement'
    Write-Source 'project/docs/old.md' "---`nstatus: superseded`nsuperseded_by: docs/current.md`n---`n# 旧接口 LegacyNeedle"
    Write-Source 'project/docs/duplicate.md' '# 当前规范 current endpoint agreement'
    Write-Source 'project/.assistant/MEMORY.md' '# 项目结论 durable summary'
    Write-Source 'project/.assistant/runtime/current.json' '{"sentinel":true}'
    Write-Source 'project/.assistant/runtime/private.md' 'RuntimeCanary'
    Write-Source 'project/node_modules/private.md' 'DependencyCanary'
    Write-Source 'project/tmp/private.md' 'TemporaryCanary'
    Write-Source 'project/packages/app/node_modules/private.md' 'NestedDependencyCanary'
    Write-Source 'project/packages/app/.assistant/runtime/private.md' 'NestedRuntimeCanary'
    Write-Source 'codex/.ignore' "sessions/`n"
    Write-Source 'codex/sessions/empty.jsonl' ''
    $messages = @(
        @{type='session_meta';payload=@{cwd=('\\?\' + $workspace)}},
        @{type='response_item';payload=@{type='message';role='user';content=@(@{type='input_text';text='SessionNeedle 用户确认接口'})}},
        @{type='response_item';payload=@{type='function_call_output';output='ToolOutputCanary'}},
        @{type='response_item';payload=@{type='message';role='assistant';channel='analysis';content=@(@{type='output_text';text='AnalysisCanary'})}},
        @{type='response_item';payload=@{type='message';role='assistant';channel='final';content=@(@{type='output_text';text='SessionAnswer 已完成接口验证'})}}
    )
    Write-Source 'codex/sessions/fixture.jsonl' (($messages | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) -join "`n")
    $other = @(@{type='session_meta';payload=@{cwd=(Join-Path $scratch 'other')}},@{type='response_item';payload=@{type='message';role='user';content=@(@{type='input_text';text='OtherProjectCanary'})}})
    Write-Source 'codex/archived_sessions/other.jsonl' (($other | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) -join "`n")
    $before = Snapshot

    $result = Invoke-Context @('recall','-Query','最小实现')
    Check ($result.results.Count -eq 1 -and $result.results[0].path.EndsWith('AGENTS.md')) 'Chinese query finds ignored root instructions'
    $read = Invoke-Context @('read','-Ref',$result.results[0].ref)
    Check ($read.text -eq '# 最小实现规范 internal agreement') 'reference reads the full document'
    $result = Invoke-Context @('recall','-Query','ENDPOINT agreement','-Budget','17')
    Check ($result.results.Count -eq 1 -and $result.excerpt_chars -le 17) 'English matching is case-insensitive, deduplicated and budgeted'
    Check ($result.results[0].excerpt -match 'endpoint') 'small excerpts retain the matching keyword'
    $result = Invoke-Context @('recall','-Query','LegacyNeedle')
    Check ($result.results.Count -eq 2 -and $result.results[0].path.EndsWith('current.md') -and $result.results[1].status -eq 'superseded') 'replacement precedes matching retired rule even with different wording'
    $result = Invoke-Context @('recall','-Query','summary')
    Check ($result.results.Count -eq 1 -and $result.results[0].path.EndsWith('MEMORY.md')) 'explicit project memory shares the same entry'
    $result = Invoke-Context @('recall','-Query','SessionNeedle')
    Check ($result.results.Count -eq 0) 'default recall does not read sessions'
    $result = Invoke-Context @('recall','-Query','SessionNeedle','-IncludeSessions')
    Check ($result.results.Count -eq 1 -and $result.results[0].kind -eq 'codex' -and $result.results[0].line -eq 2) 'explicit history query returns a workspace-bound user message'
    Check ($result.diagnostics.Count -eq 1 -and $result.diagnostics[0].status -eq 'empty') 'empty host transcript is reported, not silently hidden'
    $sessionRef = $result.results[0].ref
    $read = Invoke-Context @('read','-Ref',$sessionRef,'-IncludeSessions')
    Check ($read.text -eq 'SessionNeedle 用户确认接口') 'session read returns the selected message only'
    $writer = [IO.FileStream]::new((Join-Path $sessionHome 'sessions/fixture.jsonl'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try {
        $read = Invoke-Context @('read','-Ref',$sessionRef,'-IncludeSessions')
        Check ($read.text -match 'SessionNeedle') 'active host writer and read-only recall can coexist'
    } finally { $writer.Dispose() }
    $errorText = Invoke-Context @('read','-Ref',$sessionRef) -Fails
    Check ($errorText -match 'outside the selected sources') 'session read requires explicit source selection'
    $result = Invoke-Context @('recall','-Query','SessionAnswer','-IncludeSessions')
    Check ($result.results.Count -eq 1) 'assistant final messages are searchable'
    foreach ($query in @('IgnoredCanary','RuntimeCanary','DependencyCanary','TemporaryCanary','NestedDependencyCanary','NestedRuntimeCanary','ToolOutputCanary','AnalysisCanary','OtherProjectCanary','NoSuchKeyword')) {
        $result = Invoke-Context @('recall','-Query',$query,'-IncludeSessions')
        Check ($result.results.Count -eq 0) "excluded or absent text has no result: $query"
    }
    Check ((Snapshot) -ceq $before) 'all recall/read operations leave files and runtime state unchanged'

    $result = Invoke-Context @('recall','-Query','最小实现')
    Write-Source 'project/AGENTS.md' 'changed agreement'
    $errorText = Invoke-Context @('read','-Ref',$result.results[0].ref) -Fails
    Check ($errorText -match 'Source changed') 'changed document invalidates a reference'
    [IO.File]::AppendAllText((Join-Path $sessionHome 'sessions/fixture.jsonl'),"`n" + (@{type='event_msg';payload=@{type='task_complete'}} | ConvertTo-Json -Compress))
    $read = Invoke-Context @('read','-Ref',$sessionRef,'-IncludeSessions')
    Check ($read.text -match 'SessionNeedle') 'appending session records preserves earlier message references'
    Write-Source 'project/docs/current.md' "---`nsuperseded_by: docs/old.md`n---`nCurrent"
    $errorText = Invoke-Context @('recall','-Query','LegacyNeedle') -Fails
    Check ($errorText -match 'Cyclic superseded_by') 'cyclic replacement metadata fails explicitly'
    Write-Source 'project/docs/current.md' "---`nsuperseded_by: missing.md`n---`nCurrent"
    $errorText = Invoke-Context @('recall','-Query','LegacyNeedle') -Fails
    Check ($errorText -match 'not a project Markdown source') 'missing replacement fails explicitly'
    $errorText = Invoke-Context @('recall','-Query','   ') -Fails
    Check ($errorText -match 'requires -Query') 'empty queries are rejected at the CLI boundary'
    Write-Output "STATUS: PASS ($script:checks checks)"
} finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (!$resolvedScratch.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedScratch) -notlike 'harness-context-*') { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
