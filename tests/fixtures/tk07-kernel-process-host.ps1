[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ReceiptRoot,
    [Parameter(Mandatory)][string]$PwshPath,
    [string]$ObservationPath = '',
    [ValidateRange(0,1500)][int]$TaskkillDelayMilliseconds = 0,
    [switch]$ExitParentAfterSpawn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1')

function Write-ProcessObservation {
    param([string]$Event,$Data)
    if (-not $ObservationPath) { return }
    [IO.File]::AppendAllText($ObservationPath,([ordered]@{at=[DateTimeOffset]::Now.ToString('o');event=$Event;phase=$script:ObservationPhase;host_pid=$PID;data=$Data}|ConvertTo-Json -Depth 8 -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}

function Get-ReceiptObservations {
    foreach ($role in @('parent','leaf')) {
        $path = Join-Path $ReceiptRoot ($role+'.json')
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $row = [ordered]@{role=$role;pid=$receipt.pid;expected_start_ticks=$receipt.start_ticks;state='unknown'}
        $observed = $null
        try {
            $observed = Get-Process -Id ([int]$receipt.pid) -ErrorAction Stop
            $row.actual_start_ticks = $observed.StartTime.ToUniversalTime().Ticks
            $row.identity_matches = $row.actual_start_ticks -eq [long]$receipt.start_ticks
            $row.has_exited = $observed.HasExited
            $row.state = if (-not $row.identity_matches) { 'identity-mismatch' } elseif ($row.has_exited) { 'exited' } else { 'present' }
        } catch {
            $row.query_error = [ordered]@{type=$_.Exception.GetType().FullName;id=$_.FullyQualifiedErrorId}
            $row.state = if ($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*') { 'absent' } else { 'query-error' }
        } finally { if ($null -ne $observed) { $observed.Dispose() } }
        $row
    }
}

$script:ObservationPhase = 'product'
if ($ObservationPath) {
    $observationFull = [IO.Path]::GetFullPath($ObservationPath)
    if ($observationFull.StartsWith([IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $observationFull)) { throw 'Process observations require a new path outside the source tree' }
    $hostProcess = Get-Process -Id $PID
    Write-ProcessObservation 'probe-host' @{pid=$PID;start_ticks=$hostProcess.StartTime.ToUniversalTime().Ticks;version=$PSVersionTable.PSVersion.ToString()}
    $hostProcess.Dispose()
    # Call the current implementation unchanged. Observation never supplies the
    # cleanup result; PID/creation-time checks below remain authoritative.
    $script:OriginalKernelProcess = (Get-Command Invoke-HarnessKernelProcess).ScriptBlock
    Write-ProcessObservation 'kernel-under-test' @{function_sha256=(Get-HarnessUtf8TextSha256 $script:OriginalKernelProcess.ToString())}
    if ($TaskkillDelayMilliseconds -gt 0) {
        [void][IO.Directory]::CreateDirectory($ReceiptRoot)
        $script:CleanupProxy = Join-Path $ReceiptRoot 'cleanup-delay.exe'
        Add-Type -Path (Join-Path $RepoRoot 'tests/fixtures/tk07-cleanup-delay.cs') -OutputAssembly $script:CleanupProxy -OutputType ConsoleApplication
    }
    function Invoke-HarnessKernelProcess {
        param([string]$FilePath,[string]$WorkingDirectory,[string[]]$Arguments,[int]$TimeoutMilliseconds,[switch]$CleanGitEnvironment,[AllowNull()][string]$StandardInput=$null,[switch]$SkipTreeCleanup)
        $isTaskkill = [IO.Path]::GetFileName($FilePath) -ieq 'taskkill.exe'
        Write-ProcessObservation 'product-call' @{file=$FilePath;arguments=$(if($isTaskkill){$Arguments}else{@()});timeout_ms=$TimeoutMilliseconds;skip_tree_cleanup=[bool]$SkipTreeCleanup;owned=@(Get-ReceiptObservations)}
        try {
            $forward = @{}; foreach ($entry in $PSBoundParameters.GetEnumerator()) { $forward[$entry.Key] = $entry.Value }
            if ($isTaskkill -and $TaskkillDelayMilliseconds -gt 0) {
                $rootReceipt = Get-Content -LiteralPath (Join-Path $ReceiptRoot 'parent.json') -Raw | ConvertFrom-Json
                if ([int]$Arguments[1] -ne [int]$rootReceipt.pid) { throw 'Cleanup proxy root identity mismatch' }
                $forward.FilePath = $script:CleanupProxy
                $launchNotBefore = [DateTime]::UtcNow.AddMilliseconds($TaskkillDelayMilliseconds).Ticks
                $forward.Arguments = @($Arguments[1],[string]$rootReceipt.start_ticks,[string]$launchNotBefore)
                Write-ProcessObservation 'controlled-cleanup-delay' @{delay_ms=$TaskkillDelayMilliseconds;executable=$forward.FilePath;arguments=$forward.Arguments}
            }
            $observedResult = & $script:OriginalKernelProcess @forward
            $streams = @{}
            foreach ($name in @('StdOut','StdErr')) {
                $value = ([string]$observedResult.$name).Replace($RepoRoot,'<repo>').Replace($ReceiptRoot,'<receipts>')
                $streams[$name] = $value.Substring(0,[Math]::Min(1024,$value.Length))
            }
            Write-ProcessObservation $(if($isTaskkill){'product-taskkill-return'}else{'product-return'}) @{complete=$observedResult.Complete;exit_code=$observedResult.ExitCode;streams=$streams;owned=@(Get-ReceiptObservations)}
            return $observedResult
        } catch {
            Write-ProcessObservation 'product-exception' @{type=$_.Exception.GetType().FullName;id=$_.FullyQualifiedErrorId}
            throw
        }
    }
}

function Get-OwnedProcess {
    param($Receipt)
    $process = Get-Process -Id ([int]$Receipt.pid) -ErrorAction SilentlyContinue -ErrorVariable queryErrors
    if ($ObservationPath) { Write-ProcessObservation 'confirmation-query' @{receipt=$Receipt;found=($null-ne$process);errors=@($queryErrors|ForEach-Object{$_.FullyQualifiedErrorId});has_exited=$(if($null-ne$process){$process.HasExited}else{$null})} }
    $unexpected = @($queryErrors | Where-Object { $_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId*' })
    if ($unexpected.Count) { throw $unexpected[0] }
    if ($null -eq $process -and @($queryErrors).Count -eq 0) { throw 'Owned-process query returned no process and no absence evidence' }
    $retain = $false
    try {
        if ($null -ne $process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$Receipt.start_ticks -and -not $process.HasExited) { $retain=$true; return $process }
    } finally { if ($null -ne $process -and -not $retain) { $process.Dispose() } }
}

$values = [string[]]@('', 'with spaces', 'with"quote', 'trailing\', '中 文', "tab`tvalue")
$gitNames = @('GIT_DIR','GIT_OPTIONAL_LOCKS','GIT_TK07_SENTINEL')
$gitBefore = @{}
foreach ($name in $gitNames) { $gitBefore[$name] = [Environment]::GetEnvironmentVariable($name) }
$receipts = @()
$result = [ordered]@{host_version=$PSVersionTable.PSVersion.ToString();argv_preserved=$false;git_child_isolated=$false;caller_unchanged=$false
    timeout_incomplete=$false;timeout_exit_code=-2;receipt_count=0;root_exited=$false;tree_cleanup_confirmed=$false;cleanup_seconds=0;hash_vectors_pass=$false}
try {
    foreach ($name in $gitNames) { [Environment]::SetEnvironmentVariable($name,'tk07-parent-sentinel') }
    $probeResult = Invoke-HarnessKernelProcess -FilePath $PwshPath -WorkingDirectory $RepoRoot -TimeoutMilliseconds 30000 -CleanGitEnvironment -Arguments (
        @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $RepoRoot 'tests/fixtures/tk07-process-probe.ps1')) + $values)
    if ($probeResult.Complete -and $probeResult.ExitCode -eq 0 -and -not $probeResult.StdErr) {
        $probe = $probeResult.StdOut | ConvertFrom-Json
        $result.argv_preserved = ($probe.values | ConvertTo-Json -Compress) -ceq ($values | ConvertTo-Json -Compress)
        $result.git_child_isolated = $probe.git_dir_removed -and $probe.sentinel_removed -and $probe.optional_locks -ceq '0' -and
            $probe.terminal_prompt -ceq '0' -and $probe.no_system_config -ceq '1' -and $probe.no_system_attributes -ceq '1' -and $probe.global_config_disabled
    }
    $result.caller_unchanged = @($gitNames | Where-Object { [Environment]::GetEnvironmentVariable($_) -cne 'tk07-parent-sentinel' }).Count -eq 0
    foreach ($name in $gitNames) {
        if ($null -eq $gitBefore[$name]) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction Ignore }
        else { [Environment]::SetEnvironmentVariable($name,$gitBefore[$name]) }
    }

    [void][IO.Directory]::CreateDirectory($ReceiptRoot)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $treeArguments = @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $RepoRoot 'tests/fixtures/tk07-process-tree.ps1'),'-ReceiptRoot',$ReceiptRoot,'-PwshPath',$PwshPath)
    if ($ExitParentAfterSpawn) { $treeArguments += '-ExitParentAfterSpawn' }
    $timeout = Invoke-HarnessKernelProcess -FilePath $PwshPath -WorkingDirectory $RepoRoot -TimeoutMilliseconds 9000 -Arguments $treeArguments
    $timer.Stop()
    $result.cleanup_seconds = [Math]::Round($timer.Elapsed.TotalSeconds,3)
    $result.timeout_incomplete = -not $timeout.Complete -and -not $timeout.StdOut -and -not $timeout.StdErr
    $result.timeout_exit_code = $timeout.ExitCode
    foreach ($role in @('parent','leaf')) {
        $path = Join-Path $ReceiptRoot ($role+'.json')
        if (Test-Path -LiteralPath $path -PathType Leaf) { $receipts += Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    }
    $result.receipt_count = $receipts.Count
    # Status is sampled before the test's safety cleanup; safety cleanup cannot make this pass.
    if ($ObservationPath) { Write-ProcessObservation 'before-confirmation' @(Get-ReceiptObservations) }
    $parent = @($receipts | Where-Object role -ceq 'parent')
    $result.root_exited = $parent.Count -eq 1 -and $null -eq (Get-OwnedProcess $parent[0])
    $result.tree_cleanup_confirmed = $receipts.Count -eq 2 -and @($receipts | ForEach-Object { Get-OwnedProcess $_ }).Count -eq 0
    Write-ProcessObservation 'confirmation-result' $result

    $vectors = @(
        @{text='';normalized=$false;expected='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'},
        @{text='abc';normalized=$false;expected='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'},
        @{text='';normalized=$true;expected='01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b'},
        @{text="abc`r`n`r";normalized=$true;expected='edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb'})
    $mismatches = @(foreach ($vector in $vectors) {
        $actual = if ($vector.normalized) { Get-HarnessNormalizedTextSha256 $vector.text } else { Get-HarnessUtf8TextSha256 $vector.text }
        if ($actual -cne ('sha256:'+$vector.expected)) { $true }
    })
    $result.hash_vectors_pass = $mismatches.Count -eq 0
} finally {
    foreach ($name in $gitNames) {
        if ($null -eq $gitBefore[$name]) { Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction Ignore }
        else { [Environment]::SetEnvironmentVariable($name,$gitBefore[$name]) }
    }
    $script:ObservationPhase = 'outer-safety-cleanup'
    if ($ObservationPath) { Write-ProcessObservation 'before-safety-cleanup' @(Get-ReceiptObservations) }
    foreach ($receipt in $receipts) {
        $owned = Get-OwnedProcess $receipt
        if ($null -eq $owned) { continue }
        try { $owned.Kill($true) } catch {
            Write-ProcessObservation 'safety-kill-bool-exception' @{pid=$owned.Id;type=$_.Exception.GetType().FullName;id=$_.FullyQualifiedErrorId}
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                try {
                    & (Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe') /PID $owned.Id /T /F 2>$null | Out-Null
                    Write-ProcessObservation 'safety-taskkill-return' @{pid=$owned.Id;exit_code=$LASTEXITCODE}
                } catch { Write-ProcessObservation 'safety-taskkill-exception' @{pid=$owned.Id;type=$_.Exception.GetType().FullName;id=$_.FullyQualifiedErrorId} }
            }
            try { $owned.Kill() } catch {}
        } finally { $owned.Dispose() }
    }
    if ($ObservationPath) { Write-ProcessObservation 'after-safety-cleanup' @(Get-ReceiptObservations) }
}
$result | ConvertTo-Json -Compress
