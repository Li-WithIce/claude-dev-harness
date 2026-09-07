[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$Condition,[string]$Label) {
    $script:checks++
    if($Condition) { "[PASS] $Label" } else { $script:failures.Add($Label); "[FAIL] $Label" }
}
function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
    "[FAIL] $Message"
}
function Write-Text([string]$Path,[string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Snapshot([string]$Root) {
    @(Get-ChildItem -LiteralPath $Root -Force -Recurse | ForEach-Object {
        $relative=[IO.Path]::GetRelativePath($Root,$_.FullName)
        if($_.PSIsContainer) { 'D|'+$relative } else { 'F|'+$relative+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    } | Sort-Object) -join [Environment]::NewLine
}
function Invoke-Hook([string]$Hook,[string]$WorkingDirectory,[string]$InputText='',[hashtable]$Environment=@{},[ValidateRange(100,60000)][int]$TimeoutMilliseconds=20000) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=@(Get-Command node -CommandType Application -ErrorAction Stop)[0].Source
    $info.ArgumentList.Add($Hook);$info.WorkingDirectory=$WorkingDirectory
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    foreach($key in @('DEV_HARNESS_WORKSPACE_ROOT','CLAUDE_DEV_HARNESS_WORKSPACE_ROOT','WORKSPACE_ROOT','HARNESS_PROTOCOL')) { [void]$info.Environment.Remove($key) }
    foreach($key in $Environment.Keys) { $info.Environment[$key]=[string]$Environment[$key] }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText);$process.StandardInput.Close()
        if(-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill($true)
                if(-not $process.WaitForExit(5000)) { throw 'process tree did not exit within 5 seconds after kill' }
            } catch {
                throw ('hook fixture timed out; process-tree termination failed: '+$_.Exception.Message)
            }
            throw 'hook fixture timed out'
        }
        $output=$stdout.GetAwaiter().GetResult()
        $json=$null;try{$json=$output|ConvertFrom-Json -AsHashtable}catch{}
        return @{code=$process.ExitCode;output=$output;error=$stderr.GetAwaiter().GetResult();json=$json}
    } finally { $process.Dispose() }
}
function New-ProjectionFixture([string]$Root,[bool]$Active) {
    # Serialization/dispatch fixture only; native recovery has separate integration coverage.
    Write-Text (Join-Path $Root '.assistant/entry/task.ps1') @'
param([Parameter(Position=0)][string]$Command,[switch]$AsJson)
if($Command -cne 'status' -or -not $AsJson -or $env:HARNESS_PROTOCOL -cne 'v2'){exit 2}
[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../runtime/projection.json'))
'@
    $current=if($Active){@{task_id='private-fixture-label';version=2}}else{$null}
    Write-Text (Join-Path $Root '.assistant/runtime/projection.json') (@{operation='recovery-index';current=$current;tasks=@()}|ConvertTo-Json -Depth 10 -Compress)
    foreach($relative in @('.assistant/运行时/当前任务.md','.assistant/orchestration/current-flow.md','docs/tasks/legacy/plan.md')) {
        Write-Text (Join-Path $Root $relative) 'legacy sentinel'
    }
}
$scratch=Join-Path $RepoRoot ('tmp/runtime-hooks-'+[guid]::NewGuid().ToString('N'))
try {
    $hook=Join-Path $scratch 'hooks/stop.js'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $hook))
    foreach($name in @('stop.js','workspace-resolver.js')) { Copy-Item -LiteralPath (Join-Path $RepoRoot "runtime-hooks/claude/$name") -Destination (Join-Path (Split-Path -Parent $hook) $name) }
    $active=Join-Path $scratch 'active';$idle=Join-Path $scratch 'idle';$missing=Join-Path $scratch 'missing';$unresolved=Join-Path $scratch 'unresolved'
    New-ProjectionFixture $active $true
    New-ProjectionFixture $idle $false
    [void][IO.Directory]::CreateDirectory((Join-Path $missing '.assistant'))
    [void][IO.Directory]::CreateDirectory($unresolved)
    $timeoutRoot=Join-Path $scratch 'timeout-process-tree'
    [void][IO.Directory]::CreateDirectory($timeoutRoot)
    $timeoutHook=Join-Path $timeoutRoot 'timeout.js'
    Write-Text $timeoutHook @'
const { spawn } = require("child_process");
spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"], {
  cwd: process.cwd(), stdio: "ignore",
});
setTimeout(() => {}, 60000);
'@
    $timeoutObserved=$false
    try {
        $null=Invoke-Hook $timeoutHook $timeoutRoot '' @{} 250
    } catch {
        $timeoutObserved=$_.Exception.Message -ceq 'hook fixture timed out'
    } finally {
        Remove-DirectoryWithRetry -Path $timeoutRoot
    }
    Check ($timeoutObserved -and -not (Test-Path -LiteralPath $timeoutRoot)) 'timed-out hook process trees exit before owned fixture cleanup'
    $before=Snapshot $scratch
    $result=Invoke-Hook $hook $idle
    Check ($result.code -eq 0 -and $result.output -ceq '{}' -and $result.error -ceq '') 'idle v2 recovery projection emits empty JSON'
    $result=Invoke-Hook $hook $active
    Check ($result.code -eq 0 -and $result.json.systemMessage -match 'v2 recovery index' -and $result.json.systemMessage -match 'does not authorize runtime writes' -and $result.json.systemMessage -match 'read-only work may stop without refresh' -and $result.output -notmatch 'private-fixture-label' -and $result.error -ceq '') 'active projection emits only a non-authorizing diagnostic, never task content'
    $result=Invoke-Hook $hook $missing
    Check ($result.code -eq 0 -and $result.json.systemMessage -match 'unavailable.*missing') 'missing native entry is unavailable without a legacy fallback'
    $cases=@(
        @{label='cwd resolves each workspace independently';cwd=$idle;env=@{}},
        @{label='normalized equal environment roots override an active cwd';cwd=$active;env=@{DEV_HARNESS_WORKSPACE_ROOT=$idle;WORKSPACE_ROOT="$idle/."}},
        @{label='conflicting environment roots fail closed';cwd=$active;env=@{DEV_HARNESS_WORKSPACE_ROOT=$active;WORKSPACE_ROOT=$idle}},
        @{label='invalid environment root fails closed instead of using cwd';cwd=$active;env=@{DEV_HARNESS_WORKSPACE_ROOT=$unresolved}},
        @{label='legacy environment variable remains a workspace alias, not a v1 route';cwd=$active;env=@{CLAUDE_DEV_HARNESS_WORKSPACE_ROOT=$idle}},
        @{label='unresolved input remains inert despite an installed ancestor';cwd=$unresolved;env=@{DEV_HARNESS_WORKSPACE_ROOT=$unresolved}}
    )
    foreach($case in $cases) {
        $result=Invoke-Hook $hook $case.cwd '' $case.env
        Check ($result.code -eq 0 -and $result.output -ceq '{}' -and $result.error -ceq '') $case.label
    }
    $locks=@()
    try {
        foreach($relative in @('.assistant/运行时/当前任务.md','.assistant/orchestration/current-flow.md','docs/tasks/legacy/plan.md')) {
            $locks+= [IO.File]::Open((Join-Path $active $relative),'Open','ReadWrite','None')
        }
        $result=Invoke-Hook $hook $active
        Check ($result.code -eq 0 -and $result.json.systemMessage -match 'v2 recovery index' -and $result.error -ceq '') 'Stop never reads locked legacy pointers, flows or plans'
    } finally { foreach($lock in $locks){$lock.Dispose()} }
    Check ((Snapshot $scratch) -ceq $before) 'projection and workspace-resolution calls are zero-write'
    foreach($projection in @('not-json','{"operation":"wrong","tasks":[]}','{"operation":"recovery-index","tasks":{}}','{"operation":"recovery-index","tasks":[]}')) {
        Write-Text (Join-Path $idle '.assistant/runtime/projection.json') $projection
        $before=Snapshot $scratch
        $result=Invoke-Hook $hook $idle
        Check ($result.code -eq 0 -and $result.json.systemMessage -match 'unavailable' -and (Snapshot $scratch) -ceq $before) 'invalid projection is unavailable and zero-write'
    }
    Write-Text (Join-Path $idle '.assistant/entry/task.ps1') '[Console]::Error.WriteLine("private-error-sentinel");exit 2'
    $before=Snapshot $scratch
    $result=Invoke-Hook $hook $idle
    Check ($result.code -eq 0 -and $result.json.systemMessage -match 'unavailable' -and $result.output -notmatch 'private-error-sentinel' -and $result.error -ceq '' -and (Snapshot $scratch) -ceq $before) 'native failure does not leak child diagnostics or write state'
    $promptHook=Join-Path $RepoRoot 'runtime-hooks/claude/userpromptsubmit.js'
    $positive=@('{"prompt":"resume"}','{"prompt":"continue"}','{"prompt":"what were we doing"}','{"prompt":"继续"}','{"prompt":"恢复"}','{"prompt":"继续刚才的任务"}','{"prompt":"刚才做到哪里了"}','\u7ee7\u7eed','\u6062\u590d','\u7ee7\u7eed\u521a\u624d\u7684\u4efb\u52a1','\u521a\u624d\u505a\u5230\u54ea\u91cc\u4e86')
    $corpusPassed=$true
    foreach($inputCase in $positive) {
        $result=Invoke-Hook $promptHook $unresolved $inputCase
        if($result.code -ne 0 -or $null -eq $result.json -or $result.json['systemMessage'] -notmatch 'Resume trigger detected'){$corpusPassed=$false}
    }
    foreach($inputCase in @('{"prompt":"unrelated"}','{"prompt":"discontinue"}','')) {
        $result=Invoke-Hook $promptHook $unresolved $inputCase
        if($result.code -ne 0 -or $result.output -cne '{}'){$corpusPassed=$false}
    }
    Check $corpusPassed 'UserPromptSubmit retains the 14-case resume corpus'
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    $prefix=[IO.Path]::GetFullPath((Join-Path $RepoRoot 'tmp')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'fixture cleanup escaped its root'}
    if(Test-Path -LiteralPath $resolved){Remove-DirectoryWithRetry -Path $resolved}
}
if($failures.Count){ "STATUS: FAIL ($($failures.Count)/$checks)";exit 1 }
"STATUS: PASS ($checks checks; adapter fixtures are not Host qualification)"
exit 0
