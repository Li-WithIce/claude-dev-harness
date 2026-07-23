[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$scriptPath = Join-Path $RepoRoot 'scripts\assert-release-runner-boundary.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('release-runner-boundary-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$checks = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Pass,[string]$Fail) { if($Condition){$script:checks.Add($Pass)}else{$script:failures.Add($Fail)} }
function Invoke-Boundary {
    param([string[]]$Arguments,[hashtable]$Environment = @{},[switch]$CreateDefaultAuth)
    $isolatedHome = Join-Path $temp ('home-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($isolatedHome)
    if ($CreateDefaultAuth) {
        $codexHome = Join-Path $isolatedHome '.codex'
        [void][IO.Directory]::CreateDirectory($codexHome)
        [IO.File]::WriteAllText((Join-Path $codexHome 'auth.json'),'{}',[Text.UTF8Encoding]::new($false))
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.UseShellExecute = $false;$psi.RedirectStandardOutput = $true;$psi.RedirectStandardError = $true;$psi.CreateNoWindow = $true
    $psi.Environment['USERPROFILE']=$isolatedHome;$psi.Environment['HOME']=$isolatedHome
    foreach($name in @('HOST_BENCHMARK_CODEX_HOME','CODEX_HOME','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY','GITHUB_OUTPUT')){[void]$psi.Environment.Remove($name)}
    foreach($entry in $Environment.GetEnumerator()){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$scriptPath)+$Arguments){$psi.ArgumentList.Add([string]$argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$psi
    try{[void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not$process.WaitForExit(15000)){$process.Kill($true);throw 'boundary test timed out'};return [pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdout.GetAwaiter().GetResult().Trim();StdErr=$stderr.GetAwaiter().GetResult().Trim();Home=$isolatedHome}}finally{$process.Dispose()}
}

try {
    $outputPath = Join-Path $temp 'producer-output.txt'
    $common = @('-ProducerRunnerLabel','thin-v2-producer','-AggregatorRunnerLabel','thin-v2-aggregator','-RunId','12345','-RunAttempt','2')
    $producer = Invoke-Boundary -Arguments (@('-Mode','producer','-GitHubOutputPath',$outputPath)+$common)
    $outputLine = if(Test-Path -LiteralPath $outputPath){Get-Content -LiteralPath $outputPath -Raw -Encoding utf8}else{''}
    $digestMatch = [regex]::Match($outputLine,'(?m)^runner_account_digest=(sha256:[0-9a-f]{64})\s*$')
    $currentDigest = if($digestMatch.Success){$digestMatch.Groups[1].Value}else{''}
    Check ($producer.ExitCode-eq0-and$digestMatch.Success) 'producer emits one opaque account digest through GITHUB_OUTPUT' 'producer did not emit a valid opaque account digest'
    $sameLabel = Invoke-Boundary -Arguments @('-Mode','producer','-ProducerRunnerLabel','Shared','-AggregatorRunnerLabel','shared','-RunId','12345','-RunAttempt','2','-GitHubOutputPath',(Join-Path $temp 'same.txt'))
    Check ($sameLabel.ExitCode-ne0-and$sameLabel.StdErr-match'labels must be different') 'case-insensitive equal runner labels fail closed' 'equal runner labels were accepted'
    $emptyLabel = Invoke-Boundary -Arguments @('-Mode','producer','-ProducerRunnerLabel','','-AggregatorRunnerLabel','aggregate','-RunId','12345','-RunAttempt','2','-GitHubOutputPath',(Join-Path $temp 'empty.txt'))
    Check ($emptyLabel.ExitCode-ne0-and$emptyLabel.StdErr-match'labels must be non-empty') 'empty runner labels fail closed' 'empty runner label was accepted'
    $sameAccount = Invoke-Boundary -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest',$currentDigest,'-HostProducerAccountDigest',$currentDigest)+$common)
    Check ($sameAccount.ExitCode-ne0-and$sameAccount.StdErr-match'different Windows account') 'aggregator rejects either producer account identity' 'aggregator accepted a producer account identity'
    $missingDigest = Invoke-Boundary -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest',('sha256:'+('1'*64)))+$common)
    Check ($missingDigest.ExitCode-ne0-and$missingDigest.StdErr-match'two valid producer') 'aggregator rejects missing producer identity' 'aggregator accepted a missing producer identity'
    $malformedDigest = Invoke-Boundary -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest','invalid','-HostProducerAccountDigest',('sha256:'+('2'*64)))+$common)
    Check ($malformedDigest.ExitCode-ne0-and$malformedDigest.StdErr-match'two valid producer') 'aggregator rejects malformed producer identity' 'aggregator accepted a malformed producer identity'
    $distinctDigests = @((('sha256:'+('1'*64))),(('sha256:'+('2'*64))))
    if($currentDigest -cin $distinctDigests){$distinctDigests=@((('sha256:'+('3'*64))),(('sha256:'+('4'*64))))}
    $distinct = Invoke-Boundary -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest',$distinctDigests[0],'-HostProducerAccountDigest',$distinctDigests[1])+$common)
    Check ($distinct.ExitCode-eq0-and$distinct.StdOut-match'RELEASE_RUNNER_BOUNDARY=aggregator') 'different producer and aggregator accounts pass the boundary' 'different producer and aggregator account digests were rejected'
    $secretValue='must-not-leak-'+[guid]::NewGuid().ToString('N')
    $credential = Invoke-Boundary -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest',$distinctDigests[0],'-HostProducerAccountDigest',$distinctDigests[1])+$common) -Environment @{CODEX_ACCESS_TOKEN=$secretValue}
    Check ($credential.ExitCode-ne0-and$credential.StdErr-match'CODEX_ACCESS_TOKEN'-and$credential.StdErr -notmatch [regex]::Escape($secretValue)) 'aggregator rejects credential variables without printing values' 'aggregator credential rejection leaked or accepted a credential value'
    $defaultAuth = Invoke-Boundary -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest',$distinctDigests[0],'-HostProducerAccountDigest',$distinctDigests[1])+$common) -CreateDefaultAuth
    Check ($defaultAuth.ExitCode-ne0-and$defaultAuth.StdErr-match'default_codex_auth') 'aggregator rejects a default Codex auth file' 'aggregator accepted a default Codex auth file'
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $combined = @($producer,$sameLabel,$emptyLabel,$sameAccount,$missingDigest,$malformedDigest,$distinct,$credential,$defaultAuth | ForEach-Object { $_.StdOut; $_.StdErr }) -join "`n"
    Check ($combined -notmatch [regex]::Escape($sid) -and $combined -notmatch [regex]::Escape([Environment]::UserName)) 'runner boundary output does not reveal SID or user name' 'runner boundary output revealed SID or user name'
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force} }

Write-Output "Release runner boundary checks: $($checks.Count)"
if($failures.Count){$failures|ForEach-Object{Write-Output "- FAIL: $_"};exit 1}
Write-Output "STATUS: PASS ($($checks.Count) checks)"
