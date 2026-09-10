[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()
function Check($Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Complete($Handle) {
    if (-not $Handle.Process.WaitForExit(90000)) { $Handle.Process.Kill($true); throw 'ordinary receipt fixture timed out' }
    $result = [pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()}
    $Handle.Process.Dispose()
    return $result
}
function Invoke-Receipt($OutputRoot,[string]$Head,[string]$Outcome='success') {
    return Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $script:receiptScript -Arguments @(
        '-RepoRoot',$RepoRoot,'-OutputRoot',$OutputRoot,'-PullRequestNumber','1','-RunId','123456789',
        '-RunAttempt','2','-ExpectedHeadSha',$Head,'-BaseSha',$script:head,'-JobId','pr-core-checks',
        '-CheckName','entry-lifecycle','-Outcome',$Outcome
    ))
}
function Snapshot($Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return '' }
    return (@(Get-ChildItem -LiteralPath $Root -Force -Recurse | ForEach-Object {
        if ($_.PSIsContainer) { "D|$($_.FullName.Substring($Root.Length))" } else { "F|$($_.FullName.Substring($Root.Length))|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    } | Sort-Object) -join "`n")
}
function Test-SchemaRejected($Json,$Schema) { try { return -not (Test-Json -Json $Json -SchemaFile $Schema -ErrorAction Stop -WarningAction SilentlyContinue) } catch { return $true } }

$script:receiptScript = Join-Path $RepoRoot 'scripts\write-ordinary-ci-receipt.ps1'
$schemaPath = Join-Path $RepoRoot 'schemas\ordinary-ci-receipt.schema.json'
$script:head = (@(& git -C $RepoRoot rev-parse HEAD) -join '').Trim().ToLowerInvariant()
$repoBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('ordinary-ci-receipt-'+[guid]::NewGuid().ToString('N'))
$junction = $null
try {
    foreach ($file in @($script:receiptScript,$PSCommandPath)) {
        $tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)|Out-Null
        Check (@($errors).Count -eq 0) "$(Split-Path -Leaf $file) parses" "$(Split-Path -Leaf $file) has parse errors"
        Check (Test-FileHasUtf8Bom $file) "$(Split-Path -Leaf $file) has UTF-8 BOM" "$(Split-Path -Leaf $file) lacks UTF-8 BOM"
    }
    $validRoot = Join-Path $temp 'valid'; [void][System.IO.Directory]::CreateDirectory($validRoot)
    $valid = Invoke-Receipt $validRoot $script:head
    $receiptPath = Join-Path $validRoot 'ordinary-ci-receipt.json'
    $bytes = [System.IO.File]::ReadAllBytes($receiptPath)
    $text = [System.Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    $document = $text | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
    $safeShape = @($document.Keys).Count -eq 11 -and
        [string]$document.schema_version -ceq 'thin-harness-ordinary-ci-receipt/v1' -and
        [string]$document.head_sha -ceq $script:head -and [string]$document.checkout_sha -ceq $script:head -and
        [string]$document.outcome -ceq 'success' -and [string]$document.check_name -ceq 'entry-lifecycle'
    Check ($valid.ExitCode -eq 0 -and $safeShape -and (Test-Json -Json $text -SchemaFile $schemaPath -ErrorAction Stop)) 'receipt publishes a schema-valid exact-head machine summary' 'valid receipt generation failed or emitted the wrong binding'
    Check (-not($bytes.Length -ge 3 -and $bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF) -and @(Get-ChildItem -LiteralPath $validRoot -Force -File).Count -eq 1) 'receipt is one BOM-less UTF-8 JSON file' 'receipt encoding or artifact cardinality is invalid'
    Check ($text -notmatch '(?i)(access_token|refresh_token|cookie|prompt_text|raw_prompt|raw_trace|[A-Z]:\\\\|/home/)') 'receipt contains no prompt, credential, raw trace, or private absolute path field' 'receipt leaked a prohibited field or absolute path'
    $extra = $text | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String; $extra['raw_log'] = 'x'
    Check (Test-SchemaRejected -Json ($extra|ConvertTo-Json -Depth 20) -Schema $schemaPath) 'receipt schema rejects additional raw-log fields' 'receipt schema accepted an additional raw-log field'

    $mismatchRoot = Join-Path $temp 'mismatch'; [void][System.IO.Directory]::CreateDirectory($mismatchRoot); $before = Snapshot $mismatchRoot
    $mismatch = Invoke-Receipt $mismatchRoot ('0'*40)
    Check ($mismatch.ExitCode -eq 1 -and $mismatch.StdErr -match 'not the expected pull request head') 'receipt rejects a checkout that is not the expected head' 'receipt accepted the wrong checkout revision'
    Check ((Snapshot $mismatchRoot) -ceq $before) 'head mismatch rejection is zero-write' 'head mismatch rejection wrote output'

    $staleRoot = Join-Path $temp 'stale'; [void][System.IO.Directory]::CreateDirectory($staleRoot); [System.IO.File]::WriteAllText((Join-Path $staleRoot 'sentinel.txt'),'keep',[System.Text.UTF8Encoding]::new($false)); $before = Snapshot $staleRoot
    $stale = Invoke-Receipt $staleRoot $script:head
    Check ($stale.ExitCode -eq 1 -and $stale.StdErr -match 'output root must be empty') 'receipt refuses a stale output directory' 'receipt reused a stale output directory'
    Check ((Snapshot $staleRoot) -ceq $before) 'stale-root rejection is zero-write' 'stale-root rejection changed existing bytes'

    $outside = Join-Path $temp 'outside'; [void][System.IO.Directory]::CreateDirectory($outside); $outsideBefore = Snapshot $outside
    $junction = Join-Path $temp 'output-alias'; New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    $alias = Invoke-Receipt $junction $script:head
    Check ($alias.ExitCode -eq 1 -and $alias.StdErr -match 'reparse point') 'receipt rejects a reparse output root' 'receipt wrote through a reparse output root'
    Check ((Snapshot $outside) -ceq $outsideBefore) 'reparse rejection writes nothing to the target' 'reparse rejection changed the target'
    [System.IO.Directory]::Delete($junction,$false); $junction = $null
} finally {
    if ($null -ne $junction -and (Test-Path -LiteralPath $junction)) { try { [System.IO.Directory]::Delete($junction,$false) } catch {} }
    Remove-DirectoryWithRetry -Path $temp
}
$repoAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Check ((@($repoBefore)-join"`n") -ceq (@($repoAfter)-join"`n")) 'receipt verifier leaves repository state unchanged' 'receipt verifier changed repository state'
foreach($item in $script:checks){"[PASS] $item"};foreach($item in $script:failures){"[FAIL] $item"}
if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1}
"STATUS: PASS ($($script:checks.Count) checks)"
exit 0
