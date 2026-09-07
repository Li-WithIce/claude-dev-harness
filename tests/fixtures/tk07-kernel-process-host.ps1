[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ReceiptRoot,
    [Parameter(Mandatory)][string]$PwshPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1')

function Get-OwnedProcess {
    param($Receipt)
    $process = Get-Process -Id ([int]$Receipt.pid) -ErrorAction SilentlyContinue
    if ($null -ne $process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$Receipt.start_ticks) { return $process }
    if ($null -ne $process) { $process.Dispose() }
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
    $timeout = Invoke-HarnessKernelProcess -FilePath $PwshPath -WorkingDirectory $RepoRoot -TimeoutMilliseconds 9000 -Arguments @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $RepoRoot 'tests/fixtures/tk07-process-tree.ps1'),'-ReceiptRoot',$ReceiptRoot,'-PwshPath',$PwshPath)
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
    $parent = @($receipts | Where-Object role -ceq 'parent')
    $result.root_exited = $parent.Count -eq 1 -and $null -eq (Get-OwnedProcess $parent[0])
    $result.tree_cleanup_confirmed = $receipts.Count -eq 2 -and @($receipts | ForEach-Object { Get-OwnedProcess $_ }).Count -eq 0

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
    foreach ($receipt in $receipts) {
        $owned = Get-OwnedProcess $receipt
        if ($null -eq $owned) { continue }
        try { $owned.Kill($true) } catch {
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                & (Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe') /PID $owned.Id /T /F 2>$null | Out-Null
            }
            try { $owned.Kill() } catch {}
        } finally { $owned.Dispose() }
    }
}
$result | ConvertTo-Json -Compress
