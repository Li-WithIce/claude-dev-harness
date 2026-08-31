[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Invoke-RepoScript {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [hashtable]$Arguments,
        [string]$WorkingDirectory = '',
        [switch]$ClearWorkspaceEnvironment
    )

    $originalUserProfile = $env:USERPROFILE
    $originalHome = [Environment]::GetEnvironmentVariable('HOME', [EnvironmentVariableTarget]::Process)
    $workspaceEnvironmentNames = @('DEV_HARNESS_WORKSPACE_ROOT','CLAUDE_DEV_HARNESS_WORKSPACE_ROOT','WORKSPACE_ROOT')
    $savedWorkspaceEnvironment = [ordered]@{}
    $presentWorkspaceEnvironment = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $originalLocation = $null
    try {
        $env:USERPROFILE = $UserProfile
        $env:HOME = $UserProfile
        if ($ClearWorkspaceEnvironment) {
            foreach ($name in $workspaceEnvironmentNames) {
                if (Test-Path -LiteralPath "Env:$name") {
                    [void]$presentWorkspaceEnvironment.Add($name)
                    $savedWorkspaceEnvironment[$name] = (Get-Item -LiteralPath "Env:$name").Value
                }
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $originalLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }

        $output = @(& $ScriptPath @Arguments 2>&1)
        $scriptSucceeded = $?
        return [pscustomobject]@{
            Output   = $output
            ExitCode = if ($scriptSucceeded) { 0 } elseif ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 1 }
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($originalLocation)) {
            Set-Location -LiteralPath $originalLocation
        }

        $env:USERPROFILE = $originalUserProfile
        if ($null -eq $originalHome) {
            Remove-Item -LiteralPath 'Env:HOME' -ErrorAction SilentlyContinue
        } else {
            $env:HOME = $originalHome
        }
        if ($ClearWorkspaceEnvironment) {
            foreach ($name in $workspaceEnvironmentNames) {
                if ($presentWorkspaceEnvironment.Contains($name)) {
                    Set-Item -LiteralPath "Env:$name" -Value ([string]$savedWorkspaceEnvironment[$name])
                } else {
                    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function Invoke-GitChecked {
    param([string[]]$Arguments,[string]$Label)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed: {1}" -f $Label, ($output -join [Environment]::NewLine))
    }
    return @($output)
}

function Normalize-ContractText {
    param([string]$Text)

    return ([regex]::Replace($Text, "`r`n?", "`n")).TrimEnd([char[]]"`n")
}

function Get-TestTreeState {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return @('missing')
    }
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root)
    $records = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $normalizedRoot -Force -Recurse | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($normalizedRoot, $item.FullName)
        if ($item.PSIsContainer) {
            [void]$records.Add("D|$relative|$([int]$item.Attributes)")
        } else {
            [void]$records.Add("F|$relative|$($item.Length)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)")
        }
    }
    return @($records)
}

function Invoke-FakeCodexStatus {
    param(
        [Parameter(Mandatory = $true)][string]$BinPath,
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$StatusPath,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$ProbeHostDetails
    )

    $originalPath = $env:PATH
    try {
        $env:PATH = $BinPath + [System.IO.Path]::PathSeparator + $originalPath
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $arguments = @{
            WorkspaceRoot = $WorkspaceRoot
            RepoRoot      = $RepoRoot
        }
        if ($ProbeHostDetails) { $arguments.ProbeHostDetails = $true }
        $result = Invoke-RepoScript -UserProfile $UserProfile -ScriptPath $StatusPath -Arguments $arguments
        $timer.Stop()
        return [pscustomobject]@{ Result = $result; Elapsed = $timer.Elapsed }
    } finally {
        $env:PATH = $originalPath
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$scratchRoot = Join-Path $RepoRoot ('tmp\harness-entry-regression-' + [guid]::NewGuid().ToString('N'))

$harnessPath = Join-Path $RepoRoot 'harness.ps1'
$statusPath = Join-Path $RepoRoot 'scripts\harness-status.ps1'
$entryContractPath = Join-Path $RepoRoot 'policies\entry-contract.md'
$entryContractContent = Get-Content -LiteralPath $entryContractPath -Raw -Encoding utf8
$entryContractDigest = (Get-FileHash -LiteralPath $entryContractPath -Algorithm SHA256).Hash.ToLowerInvariant()
$statusSource = [System.IO.File]::ReadAllText($statusPath, [System.Text.UTF8Encoding]::new($false, $true))
$optionalLocksSave = '$previousGitOptionalLocks = [Environment]::GetEnvironmentVariable(''GIT_OPTIONAL_LOCKS'', [EnvironmentVariableTarget]::Process)'
$optionalLocksDisable = '[Environment]::SetEnvironmentVariable(''GIT_OPTIONAL_LOCKS'', ''0'', [EnvironmentVariableTarget]::Process)'
$optionalLocksRestore = '[Environment]::SetEnvironmentVariable(''GIT_OPTIONAL_LOCKS'', $previousGitOptionalLocks, [EnvironmentVariableTarget]::Process)'
$optionalLocksSaveIndex = $statusSource.IndexOf($optionalLocksSave, [System.StringComparison]::Ordinal)
$optionalLocksDisableIndex = $statusSource.IndexOf($optionalLocksDisable, [System.StringComparison]::Ordinal)
$protocolResolutionIndex = $statusSource.IndexOf('Get-HarnessProtocolResolution', [System.StringComparison]::Ordinal)
$optionalLocksFinallyIndex = $statusSource.IndexOf('} finally {', $protocolResolutionIndex, [System.StringComparison]::Ordinal)
$optionalLocksRestoreIndex = $statusSource.IndexOf($optionalLocksRestore, [System.StringComparison]::Ordinal)
if ([regex]::Matches($statusSource, [regex]::Escape($optionalLocksSave)).Count -eq 1 -and
    [regex]::Matches($statusSource, [regex]::Escape($optionalLocksDisable)).Count -eq 1 -and
    [regex]::Matches($statusSource, [regex]::Escape($optionalLocksRestore)).Count -eq 1 -and
    $optionalLocksSaveIndex -ge 0 -and
    $optionalLocksSaveIndex -lt $optionalLocksDisableIndex -and
    $optionalLocksDisableIndex -lt $protocolResolutionIndex -and
    $protocolResolutionIndex -lt $optionalLocksFinallyIndex -and
    $optionalLocksFinallyIndex -lt $optionalLocksRestoreIndex) {
    Add-Check 'harness-status scopes GIT_OPTIONAL_LOCKS=0 around canonical protocol resolution and restores it in finally'
} else {
    Add-Failure 'harness-status should save, disable, and finally restore process-level GIT_OPTIONAL_LOCKS around canonical protocol resolution'
}

try {
New-Item -ItemType Directory -Path $scratchRoot | Out-Null

# Case 1: bootstrap from a subdirectory inside a fresh git workspace.
$caseRoot = Join-Path $scratchRoot 'bootstrap-from-git-ancestor'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$workingDirectory = Join-Path $workspaceRoot 'src\module'
New-Item -ItemType Directory -Path $userProfile,$workingDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $workspaceRoot '.git') -Force | Out-Null

$bootstrapResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
    RepoRoot = $RepoRoot
} -WorkingDirectory $workingDirectory

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'STATUS') -ne 'PASS' -or
    ($bootstrapResult.Output -join "`n") -notmatch '(?m)^- harness-status\.ps1: PASS$') {
    Add-Failure 'harness.ps1 should bootstrap a fresh workspace with admitted v2 runtime status'
} else {
    Add-Check 'harness.ps1 bootstraps with v2 admission without requiring release qualification'
}

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'Mode') -ne 'bootstrap-workspace') {
    Add-Failure 'harness.ps1 should report bootstrap-workspace mode for a fresh workspace'
} else {
    Add-Check 'harness.ps1 reports bootstrap-workspace mode for a fresh workspace'
}

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'WorkspaceRoot') -ne $workspaceRoot) {
    Add-Failure 'harness.ps1 should infer the git ancestor as WorkspaceRoot during bootstrap'
} else {
    Add-Check 'harness.ps1 infers the git ancestor as WorkspaceRoot during bootstrap'
}

if (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot '.assistant') -PathType Container)) {
    Add-Failure 'harness.ps1 should create .assistant during bootstrap'
} else {
    Add-Check 'harness.ps1 creates .assistant during bootstrap'
}

$entryShimPath = Join-Path $workspaceRoot 'AGENTS.md'
$entryShimContent = Get-Content -LiteralPath $entryShimPath -Raw -Encoding utf8
$contractPattern = '(?ms)^<!-- BEGIN GENERATED ENTRY CONTRACT -->\r?\n<!-- source-sha256: (?<digest>[0-9a-f]{64}) -->\r?\n(?<body>.*?)\r?\n<!-- END GENERATED ENTRY CONTRACT -->$'
$contractMatches = [regex]::Matches($entryShimContent, $contractPattern)
if ($contractMatches.Count -eq 1 -and
    $contractMatches[0].Groups['digest'].Value -ceq $entryContractDigest -and
    (Normalize-ContractText $contractMatches[0].Groups['body'].Value) -ceq (Normalize-ContractText $entryContractContent)) {
    Add-Check 'workspace AGENTS contains the one current canonical v2 admission contract'
} else {
    Add-Failure 'workspace AGENTS generated contract is missing, duplicated or stale'
}
foreach ($retired in @('entry/AGENTS.md','entry/advance-stage.ps1','entry/validate-lite-artifacts.ps1','运行时/当前任务.md')) {
    if (Test-Path -LiteralPath (Join-Path $workspaceRoot ('.assistant/'+$retired))) {
        Add-Failure ("fresh installation contains retired v1 asset: " + $retired)
    } else {
        Add-Check ("fresh installation omits retired v1 asset: " + $retired)
    }
}
if (Test-Path -LiteralPath (Join-Path $workspaceRoot '.assistant\工作流') -PathType Container) {
    Add-Failure 'harness.ps1 should use minimal vault profile for a fresh workspace by default'
} else {
    Add-Check 'harness.ps1 uses minimal vault profile for a fresh workspace by default'
}

$statusWorkspaceBefore = @(Get-TestTreeState -Root $workspaceRoot)
# PowerShell updates this host-owned startup cache asynchronously; it is not Harness install state.
$powerShellStartupProfilePrefix = 'F|AppData\Local\Microsoft\PowerShell\StartupProfileData-'
$statusUserBefore = @(Get-TestTreeState -Root $userProfile | Where-Object { -not $_.StartsWith($powerShellStartupProfilePrefix, [StringComparison]::OrdinalIgnoreCase) })
$statusRepoBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
$statusGitOptionalLocksBefore = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS', [EnvironmentVariableTarget]::Process)
$statusResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $statusPath -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}
$statusWorkspaceAfter = @(Get-TestTreeState -Root $workspaceRoot)
$statusUserAfter = @(Get-TestTreeState -Root $userProfile | Where-Object { -not $_.StartsWith($powerShellStartupProfilePrefix, [StringComparison]::OrdinalIgnoreCase) })
$statusRepoAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
$statusGitOptionalLocksAfter = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS', [EnvironmentVariableTarget]::Process)
$statusText = $statusResult.Output -join "`n"
if ($statusResult.ExitCode -eq 0 -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'STATUS') -eq 'PASS' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'host_product') -eq 'codex' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'host_version_actual') -eq 'unknown' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'host_details_probed') -eq 'false' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'capability_observation') -eq 'observed' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'capability_workspace_protocol_config') -eq 'true' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'capability_hook_status_query') -eq 'unavailable' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'protected_policy') -eq 'verified' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'runtime_default') -eq 'missing' -and
    (Get-StatusLineValue -Output $statusResult.Output -Prefix 'workspace_config') -eq 'missing' -and
    $statusText -notmatch '(?m)^(host_version_expected|qualification_profile|canonical_report|hook_installed|hook_trust|hook_callable):' -and
    $statusText -notmatch 'Host capability observation|Host version observation') {
    Add-Check 'default harness-status reports only required Runtime facts without probing Host details or warning on optional facts'
} else {
    Add-Failure 'harness-status should report the ordinary runtime health surface truthfully'
}
if (@(Compare-Object $statusWorkspaceBefore $statusWorkspaceAfter -CaseSensitive).Count -eq 0 -and
    @(Compare-Object $statusUserBefore $statusUserAfter -CaseSensitive).Count -eq 0 -and
    @(Compare-Object $statusRepoBefore $statusRepoAfter -CaseSensitive).Count -eq 0 -and
    [string]$statusGitOptionalLocksBefore -ceq [string]$statusGitOptionalLocksAfter) {
    Add-Check 'harness-status is zero-write across workspace, user install state, and repository status'
} else {
    Add-Failure 'harness-status changed workspace, user install state, or repository status'
}

$hookPath = Join-Path $userProfile '.codex\hooks.json'
$hookBytes = [System.IO.File]::ReadAllBytes($hookPath)
$hookDocument = [System.Text.UTF8Encoding]::new($false, $true).GetString($hookBytes) | ConvertFrom-Json -AsHashtable -Depth 32
$hookDocument['bounded_reader_padding'] = 'x' * 4MB
$oversizedHookBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($hookDocument | ConvertTo-Json -Depth 32 -Compress))
if ($oversizedHookBytes.Length -le 4MB) {
    throw 'oversized Hook fixture did not exceed the production size limit'
}
try {
    [System.IO.File]::WriteAllBytes($hookPath, $oversizedHookBytes)
    $oversizedHookProbe = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $statusPath -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }
} finally {
    [System.IO.File]::WriteAllBytes($hookPath, $hookBytes)
}
if ($oversizedHookProbe.ExitCode -eq 0 -and
    (Get-StatusLineValue -Output $oversizedHookProbe.Output -Prefix 'STATUS') -eq 'PASS' -and
    (Get-StatusLineValue -Output $oversizedHookProbe.Output -Prefix 'capability_hook_status_query') -eq 'unavailable' -and
    ($oversizedHookProbe.Output -join "`n") -notmatch '(?m)^hook_installed:') {
    Add-Check 'ordinary harness-status does not read user Hook qualification state'
} else {
    Add-Failure 'ordinary harness-status should remain independent of user Hook qualification state'
}

$fakeCodexBin = Join-Path $caseRoot 'fake-codex-exact-version'
[void][System.IO.Directory]::CreateDirectory($fakeCodexBin)
$defaultProbeSentinel = Join-Path $fakeCodexBin 'default-probe-sentinel.txt'
[System.IO.File]::WriteAllText(
    (Join-Path $fakeCodexBin 'codex.ps1'),
    "[IO.File]::WriteAllText('$($defaultProbeSentinel.Replace("'", "''"))','called')`r`n[Console]::Out.WriteLine('codex-cli 0.144.4')`r`n",
    [System.Text.UTF8Encoding]::new($false))
$defaultVersionProbe = Invoke-FakeCodexStatus -BinPath $fakeCodexBin -UserProfile $userProfile -StatusPath $statusPath -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot
if (-not (Test-Path -LiteralPath $defaultProbeSentinel) -and
    (Get-StatusLineValue -Output $defaultVersionProbe.Result.Output -Prefix 'host_version_actual') -eq 'unknown' -and
    (Get-StatusLineValue -Output $defaultVersionProbe.Result.Output -Prefix 'host_details_probed') -eq 'false') {
    Add-Check 'default harness-status does not execute the Codex version probe'
} else {
    Add-Failure 'default harness-status should not execute the Codex version probe'
}
$exactVersionProbe = Invoke-FakeCodexStatus -BinPath $fakeCodexBin -UserProfile $userProfile -StatusPath $statusPath -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -ProbeHostDetails
if ($exactVersionProbe.Result.ExitCode -eq 0 -and
    (Get-StatusLineValue -Output $exactVersionProbe.Result.Output -Prefix 'host_version_actual') -eq '0.144.4' -and
    (Get-StatusLineValue -Output $exactVersionProbe.Result.Output -Prefix 'host_details_probed') -eq 'true' -and
    ($exactVersionProbe.Result.Output -join "`n") -notmatch '(?m)^host_version_expected:') {
    Add-Check 'harness-status reports an observed Host version as a fact without a qualification target'
} else {
    Add-Failure 'harness-status should report the observed Host version without a qualification target'
}

$fakeCodexBin = Join-Path $caseRoot 'fake-codex-mismatched-version'
[void][System.IO.Directory]::CreateDirectory($fakeCodexBin)
[System.IO.File]::WriteAllText(
    (Join-Path $fakeCodexBin 'codex.ps1'),
    "[Console]::Out.WriteLine('codex-cli 9.9.9')`r`n",
    [System.Text.UTF8Encoding]::new($false))
$mismatchedVersionProbe = Invoke-FakeCodexStatus -BinPath $fakeCodexBin -UserProfile $userProfile -StatusPath $statusPath -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -ProbeHostDetails
if ($mismatchedVersionProbe.Result.ExitCode -eq 0 -and
    (Get-StatusLineValue -Output $mismatchedVersionProbe.Result.Output -Prefix 'host_version_actual') -eq '9.9.9' -and
    ($mismatchedVersionProbe.Result.Output -join "`n") -notmatch '(?i)version.mismatch|host_version_expected') {
    Add-Check 'harness-status accepts a well-formed newer Host version without a mismatch conclusion'
} else {
    Add-Failure 'harness-status should preserve a newer Host version without qualification mismatch'
}

$fakeCodexBin = Join-Path $caseRoot 'fake-codex-malformed-version'
[void][System.IO.Directory]::CreateDirectory($fakeCodexBin)
[System.IO.File]::WriteAllText(
    (Join-Path $fakeCodexBin 'codex.ps1'),
    "[Console]::Out.WriteLine('not-a-codex-version')`r`n",
    [System.Text.UTF8Encoding]::new($false))
$malformedVersionProbe = Invoke-FakeCodexStatus -BinPath $fakeCodexBin -UserProfile $userProfile -StatusPath $statusPath -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -ProbeHostDetails
if ($malformedVersionProbe.Result.ExitCode -eq 0 -and
    (Get-StatusLineValue -Output $malformedVersionProbe.Result.Output -Prefix 'host_version_actual') -eq 'unknown' -and
    ($malformedVersionProbe.Result.Output -join "`n") -notmatch '(?i)version.mismatch|host_version_expected') {
    Add-Check 'harness-status rejects malformed Codex Host version output as unavailable'
} else {
    Add-Failure 'harness-status should not classify malformed Host output as a version mismatch'
}

$fakeCodexBin = Join-Path $caseRoot 'fake-codex-hang'
[void][System.IO.Directory]::CreateDirectory($fakeCodexBin)
[System.IO.File]::WriteAllText(
    (Join-Path $fakeCodexBin 'codex.ps1'),
    "Start-Sleep -Seconds 120`r`n",
    [System.Text.UTF8Encoding]::new($false))
$hangProbe = Invoke-FakeCodexStatus -BinPath $fakeCodexBin -UserProfile $userProfile -StatusPath $statusPath -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -ProbeHostDetails
if ($hangProbe.Result.ExitCode -eq 0 -and
    $hangProbe.Elapsed.TotalSeconds -lt 10 -and
    (Get-StatusLineValue -Output $hangProbe.Result.Output -Prefix 'STATUS') -eq 'PASS' -and
    (Get-StatusLineValue -Output $hangProbe.Result.Output -Prefix 'host_version_actual') -eq 'unknown') {
    Add-Check 'harness-status bounds a hanging Codex version probe and reports unavailable'
} else {
    Add-Failure 'harness-status should terminate a hanging Codex version probe within its bounded timeout'
}

$fakeCodexBin = Join-Path $caseRoot 'fake-codex-inherited-pipe'
[void][System.IO.Directory]::CreateDirectory($fakeCodexBin)
$inheritedPipeScript = @'
$childInfo = [System.Diagnostics.ProcessStartInfo]::new()
$childInfo.FileName = (Get-Process -Id $PID).Path
$childInfo.UseShellExecute = $false
$childInfo.CreateNoWindow = $true
foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 8')) {
    $childInfo.ArgumentList.Add($argument)
}
[void][System.Diagnostics.Process]::Start($childInfo)
'@
[System.IO.File]::WriteAllText(
    (Join-Path $fakeCodexBin 'codex.ps1'),
    $inheritedPipeScript,
    [System.Text.UTF8Encoding]::new($false))
$inheritedPipeProbe = Invoke-FakeCodexStatus -BinPath $fakeCodexBin -UserProfile $userProfile -StatusPath $statusPath -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -ProbeHostDetails
if ($inheritedPipeProbe.Result.ExitCode -eq 0 -and
    $inheritedPipeProbe.Elapsed.TotalSeconds -lt 10 -and
    (Get-StatusLineValue -Output $inheritedPipeProbe.Result.Output -Prefix 'host_version_actual') -eq 'unknown') {
    Add-Check 'harness-status bounds inherited output pipes after the Codex probe root exits'
} else {
    Add-Failure 'harness-status should not wait indefinitely when a Codex probe child inherits output pipes'
}

$fakeCodexBin = Join-Path $caseRoot 'fake-codex-output-flood'
[void][System.IO.Directory]::CreateDirectory($fakeCodexBin)
[System.IO.File]::WriteAllText(
    (Join-Path $fakeCodexBin 'codex.ps1'),
    "[Console]::Out.Write(('x' * 131072))`r`n",
    [System.Text.UTF8Encoding]::new($false))
$floodProbe = Invoke-FakeCodexStatus -BinPath $fakeCodexBin -UserProfile $userProfile -StatusPath $statusPath -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -ProbeHostDetails
if ($floodProbe.Result.ExitCode -eq 0 -and
    $floodProbe.Elapsed.TotalSeconds -lt 10 -and
    (Get-StatusLineValue -Output $floodProbe.Result.Output -Prefix 'host_version_actual') -eq 'unknown') {
    Add-Check 'harness-status drains but rejects truncated Codex version output'
} else {
    Add-Failure 'harness-status should fail closed when Codex version output exceeds the retention cap'
}

# Case 2: auto vault detection should not treat one weak marker as an existing full vault.
$caseRoot = Join-Path $scratchRoot 'auto-ignores-weak-vault-marker'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
New-Item -ItemType Directory -Path $userProfile,(Join-Path $workspaceRoot '.assistant\配置') -Force | Out-Null

$weakMarkerInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($weakMarkerInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed when only one weak full-vault marker exists'
} elseif (Test-Path -LiteralPath (Join-Path $workspaceRoot '.assistant\工作流') -PathType Container) {
    Add-Failure 'auto vault detection should keep a workspace with only .assistant\配置 on minimal profile'
} else {
    Add-Check 'auto vault detection ignores a single weak full-vault marker'
}

# Case 3: update an existing workspace from a descendant path and repair managed drift.
$caseRoot = Join-Path $scratchRoot 'update-existing-workspace'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$workingDirectory = Join-Path $workspaceRoot '.assistant'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
    VaultProfile  = 'full'
}

if ($installResult.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the harness update regression runs'
} else {
    $sharedMemoryProtocolLeaf = [string]::Concat(([int[]](20849,20139,35760,24518,21327,35758,46,109,100) | ForEach-Object { [char]$_ }))
    $protocolPath = @(Get-ChildItem -LiteralPath (Join-Path $workspaceRoot '.assistant') -Recurse -File | Where-Object {
            $_.Name -eq $sharedMemoryProtocolLeaf
        } | Select-Object -First 1)

    if ($protocolPath.Count -ne 1) {
        Add-Failure 'unable to resolve managed protocol file inside the installed workspace'
    } else {
        Add-Content -LiteralPath $protocolPath[0].FullName -Value "`nLOCAL-DRIFT" -Encoding utf8

        $updateResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
            RepoRoot = $RepoRoot
        } -WorkingDirectory $workingDirectory

        if ((Get-StatusLineValue -Output $updateResult.Output -Prefix 'STATUS') -ne 'PASS' -or
            ($updateResult.Output -join "`n") -notmatch '(?m)^- harness-status\.ps1: PASS$') {
            Add-Failure 'harness.ps1 should update an existing workspace with admitted v2 runtime status'
        } else {
            Add-Check 'harness.ps1 preserves successful update and runs truthful advisory Desktop health status'
        }

        if ((Get-StatusLineValue -Output $updateResult.Output -Prefix 'Mode') -ne 'update-existing-workspace') {
            Add-Failure 'harness.ps1 should report update-existing-workspace mode for an installed workspace'
        } else {
            Add-Check 'harness.ps1 reports update-existing-workspace mode for an installed workspace'
        }

        $protocolContent = Get-Content -LiteralPath $protocolPath[0].FullName -Raw -Encoding utf8
        if ($protocolContent.Contains('LOCAL-DRIFT')) {
            Add-Failure 'harness.ps1 should repair managed workspace drift through update-managed-assets'
        } else {
            Add-Check 'harness.ps1 repairs managed workspace drift through update-managed-assets'
        }
    }
}

# Case 4: a git submodule (.git is a gitlink file) inside an installed workspace stays part of the parent.
$caseRoot = Join-Path $scratchRoot 'submodule-stays-in-parent'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$submoduleRepo = Join-Path $workspaceRoot 'vendor\submodule'
$submoduleWorking = Join-Path $submoduleRepo 'src'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$submoduleInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($submoduleInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the submodule regression runs'
} else {
    $submoduleSource = Join-Path $caseRoot 'submodule-source'
    $submoduleSourceFile = Join-Path $submoduleSource 'src\source.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $submoduleSourceFile) -Force | Out-Null
    [System.IO.File]::WriteAllText($submoduleSourceFile,"submodule`n",[System.Text.UTF8Encoding]::new($false))
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'init','--quiet') -Label 'submodule source init')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'config','user.email','harness@example.invalid') -Label 'submodule source email config')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'config','user.name','Harness') -Label 'submodule source name config')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'add','.') -Label 'submodule source add')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'commit','--quiet','-m','source') -Label 'submodule source commit')

    $parentAnchor = Join-Path $workspaceRoot 'parent.txt'
    [System.IO.File]::WriteAllText($parentAnchor,"parent`n",[System.Text.UTF8Encoding]::new($false))
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'init','--quiet') -Label 'submodule parent init')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.email','harness@example.invalid') -Label 'submodule parent email config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.name','Harness') -Label 'submodule parent name config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'add','parent.txt') -Label 'submodule parent add')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'commit','--quiet','-m','parent') -Label 'submodule parent commit')
    [void](Invoke-GitChecked -Arguments @('-c','protocol.file.allow=always','-C',$workspaceRoot,'submodule','add','--quiet',$submoduleSource.Replace('\','/'),'vendor/submodule') -Label 'submodule add')

    $submoduleResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
        SkipStatus = $true
    } -WorkingDirectory $submoduleWorking

    if ((Get-StatusLineValue -Output $submoduleResult.Output -Prefix 'WorkspaceRoot') -ne $workspaceRoot) {
        Add-Failure 'harness.ps1 should resolve a submodule to the parent installed workspace, not its gitlink root'
    } else {
        Add-Check 'harness.ps1 keeps a git submodule (.git file) inside the parent installed workspace'
    }

    if ((Get-StatusLineValue -Output $submoduleResult.Output -Prefix 'Mode') -ne 'update-existing-workspace') {
        Add-Failure 'harness.ps1 should report update-existing-workspace mode for a submodule under an installed workspace'
    } else {
        Add-Check 'harness.ps1 treats a submodule as content of the parent workspace'
    }

    if (Test-Path -LiteralPath (Join-Path $submoduleRepo '.assistant') -PathType Container) {
        Add-Failure 'harness.ps1 should not bootstrap a new .assistant inside a submodule without explicit -WorkspaceRoot'
    } else {
        Add-Check 'harness.ps1 does not split a submodule into its own workspace'
    }
}

# Case 5: a linked worktree inside an installed workspace bootstraps without inheriting parent task authority.
$caseRoot = Join-Path $scratchRoot 'linked-worktree-isolated'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$linkedWorktree = Join-Path $workspaceRoot '.worktrees\feature'
$linkedWorking = Join-Path $linkedWorktree 'src'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$worktreeInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($worktreeInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the linked-worktree regression runs'
} else {
    $parentAnchor = Join-Path $workspaceRoot 'parent.txt'
    [System.IO.File]::WriteAllText($parentAnchor,"parent`n",[System.Text.UTF8Encoding]::new($false))
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'init','--quiet') -Label 'worktree parent init')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.email','harness@example.invalid') -Label 'worktree parent email config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.name','Harness') -Label 'worktree parent name config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'add','parent.txt') -Label 'worktree parent add')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'commit','--quiet','-m','parent') -Label 'worktree parent commit')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'worktree','add','--quiet','-b','feature',$linkedWorktree,'HEAD') -Label 'linked worktree add')
    New-Item -ItemType Directory -Path $linkedWorking -Force | Out-Null

    $parentSentinels = [ordered]@{
        '.assistant\runtime\current.json' = '{"parent":"current"}'
        '.assistant\runtime\tasks\parent-task\task.json' = '{"parent":"task"}'
        '.assistant\runtime\tasks\parent-task\approvals\apr_parent.json' = '{"parent":"approval"}'
    }
    $parentSentinelBytes = [ordered]@{}
    foreach ($relativePath in $parentSentinels.Keys) {
        $target = Join-Path $workspaceRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$parentSentinels[$relativePath])
        [System.IO.File]::WriteAllBytes($target,$bytes)
        $parentSentinelBytes[$relativePath] = $bytes
    }

    $gitEnvironmentNames = @('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR')
    $savedGitEnvironment = [ordered]@{}
    $presentGitEnvironment = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $gitEnvironmentNames) {
        if (Test-Path -LiteralPath "Env:$name") {
            [void]$presentGitEnvironment.Add($name)
            $savedGitEnvironment[$name] = (Get-Item -LiteralPath "Env:$name").Value
        }
    }
    try {
        $env:GIT_DIR = Join-Path $workspaceRoot '.git'
        $env:GIT_WORK_TREE = $workspaceRoot
        $env:GIT_COMMON_DIR = Join-Path $workspaceRoot '.git'
        $worktreeResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
            RepoRoot = $RepoRoot
        } -WorkingDirectory $linkedWorking
    } finally {
        foreach ($name in $gitEnvironmentNames) {
            if ($presentGitEnvironment.Contains($name)) {
                Set-Item -LiteralPath "Env:$name" -Value ([string]$savedGitEnvironment[$name])
            } else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }

    if ((Get-StatusLineValue -Output $worktreeResult.Output -Prefix 'STATUS') -ne 'PASS' -or
        (Get-StatusLineValue -Output $worktreeResult.Output -Prefix 'WorkspaceRoot') -ne $linkedWorktree -or
        (Get-StatusLineValue -Output $worktreeResult.Output -Prefix 'Mode') -ne 'bootstrap-workspace' -or
        ($worktreeResult.Output -join "`n") -notmatch '(?m)^- harness-status\.ps1: PASS$' -or
        ($worktreeResult.Output -join "`n") -match '(?m)^- harness-status\.ps1: SKIP$') {
        Add-Failure 'harness.ps1 should bootstrap the linked worktree and run advisory status without inheriting parent state'
    } else {
        Add-Check 'harness.ps1 bootstraps a linked worktree and runs non-SKIP status despite inherited Git repository variables'
    }

    $parentUnchanged = $true
    $worktreeDidNotCopy = $true
    foreach ($relativePath in $parentSentinels.Keys) {
        $parentPath = Join-Path $workspaceRoot $relativePath
        $worktreePath = Join-Path $linkedWorktree $relativePath
        if (-not (Test-Path -LiteralPath $parentPath -PathType Leaf) -or
            ([System.IO.File]::ReadAllBytes($parentPath) -join ',') -cne (@($parentSentinelBytes[$relativePath]) -join ',')) {
            $parentUnchanged = $false
        }
        if (Test-Path -LiteralPath $worktreePath) {
            $worktreeDidNotCopy = $false
        }
    }
    if ($parentUnchanged -and $worktreeDidNotCopy) {
        Add-Check 'linked worktree bootstrap neither changes nor copies parent current, task, or Approval state'
    } else {
        Add-Failure 'linked worktree bootstrap changed or copied parent current, task, or Approval state'
    }
}

# Case 6: an invalid gitfile fails closed instead of inheriting a parent workspace.
$caseRoot = Join-Path $scratchRoot 'invalid-gitfile-fails-closed'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$invalidRepo = Join-Path $workspaceRoot 'projects\invalid'
$invalidWorking = Join-Path $invalidRepo 'src'
New-Item -ItemType Directory -Path $userProfile,$invalidWorking -Force | Out-Null
$invalidInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}
if ($invalidInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the invalid-gitfile regression runs'
} else {
    [System.IO.File]::WriteAllText((Join-Path $invalidRepo '.git'),'gitdir: missing',[System.Text.Encoding]::ASCII)
    $invalidResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
        SkipStatus = $true
    } -WorkingDirectory $invalidWorking
    if ((Get-StatusLineValue -Output $invalidResult.Output -Prefix 'STATUS') -eq 'FAIL' -and
        ($invalidResult.Output -join "`n") -match 'Unable to classify gitfile workspace safely') {
        Add-Check 'harness.ps1 fails closed when Git cannot classify a nested gitfile'
    } else {
        Add-Failure 'harness.ps1 should fail closed when Git cannot classify a nested gitfile'
    }
}

# Case 7: an independent nested repo (.git is a directory) under an installed workspace still bootstraps its own workspace.
$caseRoot = Join-Path $scratchRoot 'independent-nested-repo'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$nestedRepo = Join-Path $workspaceRoot 'projects\nested'
$nestedWorking = Join-Path $nestedRepo 'src'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$nestedInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($nestedInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the independent-nested-repo regression runs'
} else {
    New-Item -ItemType Directory -Path (Join-Path $nestedRepo '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path $nestedWorking -Force | Out-Null

    $nestedResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
    } -WorkingDirectory $nestedWorking

    if ((Get-StatusLineValue -Output $nestedResult.Output -Prefix 'WorkspaceRoot') -ne $nestedRepo) {
        Add-Failure 'harness.ps1 should bootstrap an independent nested repo (.git directory) at its own git root'
    } else {
        Add-Check 'harness.ps1 bootstraps an independent nested repo (.git directory) at its own git root'
    }

    if ((Get-StatusLineValue -Output $nestedResult.Output -Prefix 'Mode') -ne 'bootstrap-workspace') {
        Add-Failure 'harness.ps1 should report bootstrap-workspace mode for an independent nested repo'
    } else {
        Add-Check 'harness.ps1 reports bootstrap-workspace mode for an independent nested repo'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $nestedRepo '.assistant') -PathType Container)) {
        Add-Failure 'harness.ps1 should create .assistant when bootstrapping an independent nested repo'
    } else {
        Add-Check 'harness.ps1 creates a separate workspace for an independent nested repo'
    }
}

# Case 8: an independent nested repo with a separate git directory bootstraps its own workspace.
$caseRoot = Join-Path $scratchRoot 'separate-git-dir-isolated'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$nestedRepo = Join-Path $workspaceRoot 'projects\nested'
$nestedWorking = Join-Path $nestedRepo 'src'
$separateGitDirectory = Join-Path $caseRoot 'git-dirs\nested.git'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$separateInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($separateInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the separate-git-dir regression runs'
} else {
    $parentSentinels = [ordered]@{
        '.assistant\runtime\current.json' = '{"parent":"current"}'
        '.assistant\runtime\tasks\parent-task\task.json' = '{"parent":"task"}'
        '.assistant\runtime\tasks\parent-task\approvals\apr_parent.json' = '{"parent":"approval"}'
    }
    $parentSentinelBytes = [ordered]@{}
    foreach ($relativePath in $parentSentinels.Keys) {
        $target = Join-Path $workspaceRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$parentSentinels[$relativePath])
        [System.IO.File]::WriteAllBytes($target,$bytes)
        $parentSentinelBytes[$relativePath] = $bytes
    }

    New-Item -ItemType Directory -Path $nestedWorking,(Split-Path -Parent $separateGitDirectory) -Force | Out-Null
    [void](Invoke-GitChecked -Arguments @('init','--quiet',("--separate-git-dir=$separateGitDirectory"),$nestedRepo) -Label 'separate-git-dir init')
    if (-not (Test-Path -LiteralPath (Join-Path $nestedRepo '.git') -PathType Leaf)) {
        Add-Failure 'separate-git-dir fixture should create a .git file'
    }

    $separateResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
        SkipStatus = $true
    } -WorkingDirectory $nestedWorking

    if ((Get-StatusLineValue -Output $separateResult.Output -Prefix 'STATUS') -eq 'PASS' -and
        (Get-StatusLineValue -Output $separateResult.Output -Prefix 'WorkspaceRoot') -eq $nestedRepo -and
        (Get-StatusLineValue -Output $separateResult.Output -Prefix 'WorkspaceRootSource') -eq 'git-ancestor' -and
        (Get-StatusLineValue -Output $separateResult.Output -Prefix 'Mode') -eq 'bootstrap-workspace' -and
        (Test-Path -LiteralPath (Join-Path $nestedRepo '.assistant') -PathType Container)) {
        Add-Check 'harness.ps1 treats a separate-git-dir repository as independent, not as a submodule'
    } else {
        Add-Failure 'harness.ps1 should bootstrap a separate-git-dir repository as an independent workspace'
    }

    $parentUnchanged = $true
    $nestedDidNotCopy = $true
    foreach ($relativePath in $parentSentinels.Keys) {
        $parentPath = Join-Path $workspaceRoot $relativePath
        $nestedPath = Join-Path $nestedRepo $relativePath
        if (-not (Test-Path -LiteralPath $parentPath -PathType Leaf) -or
            ([System.IO.File]::ReadAllBytes($parentPath) -join ',') -cne (@($parentSentinelBytes[$relativePath]) -join ',')) {
            $parentUnchanged = $false
        }
        if (Test-Path -LiteralPath $nestedPath) {
            $nestedDidNotCopy = $false
        }
    }
    if ($parentUnchanged -and $nestedDidNotCopy) {
        Add-Check 'separate-git-dir bootstrap neither changes nor copies parent task authority'
    } else {
        Add-Failure 'separate-git-dir bootstrap changed or copied parent current, task, or Approval state'
    }
}

# Case 9: running from the repo root without an explicit workspace should fail safely.
$repoRootCase = Join-Path $scratchRoot 'repo-root-guard'
$repoRootUserProfile = Join-Path $repoRootCase 'user'
New-Item -ItemType Directory -Path $repoRootUserProfile -Force | Out-Null

$guardResult = Invoke-RepoScript -UserProfile $repoRootUserProfile -ScriptPath $harnessPath -Arguments @{
    RepoRoot = $RepoRoot
} -WorkingDirectory $RepoRoot -ClearWorkspaceEnvironment

if ((Get-StatusLineValue -Output $guardResult.Output -Prefix 'STATUS') -ne 'FAIL') {
    Add-Failure 'harness.ps1 should fail safely when run from the harness repo root without WorkspaceRoot'
} else {
    Add-Check 'harness.ps1 fails safely when run from the harness repo root without WorkspaceRoot'
}

# Case 10: a Harness source RepoRoot nested inside an installed workspace cannot escape to that parent.
$caseRoot = Join-Path $scratchRoot 'repo-boundary'
$userProfile = Join-Path $caseRoot 'u'
$workspaceRoot = Join-Path $caseRoot 'w'
$nestedRepo = Join-Path $workspaceRoot 'r'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$boundaryInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
    Preset        = 'core'
}
if ($boundaryInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the nested Harness RepoRoot boundary regression runs'
} else {
    [void](Invoke-GitChecked -Arguments @('clone','--quiet','--no-hardlinks',$RepoRoot,$nestedRepo) -Label 'nested Harness RepoRoot clone')
    Copy-Item -LiteralPath $harnessPath -Destination (Join-Path $nestedRepo 'harness.ps1') -Force

    $parentAssistantBefore = Get-TestTreeState -Root (Join-Path $workspaceRoot '.assistant')
    $parentAgentsBefore = (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'AGENTS.md') -Algorithm SHA256).Hash
    $nestedRepoBefore = @(& git -C $nestedRepo status --porcelain --untracked-files=all)
    $boundaryResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $nestedRepo 'harness.ps1') -Arguments @{
        RepoRoot = $nestedRepo
    } -WorkingDirectory $nestedRepo -ClearWorkspaceEnvironment
    $parentAssistantAfter = Get-TestTreeState -Root (Join-Path $workspaceRoot '.assistant')
    $parentAgentsAfter = (Get-FileHash -LiteralPath (Join-Path $workspaceRoot 'AGENTS.md') -Algorithm SHA256).Hash
    $nestedRepoAfter = @(& git -C $nestedRepo status --porcelain --untracked-files=all)

    if ($boundaryResult.ExitCode -eq 2 -and
        (Get-StatusLineValue -Output $boundaryResult.Output -Prefix 'STATUS') -eq 'FAIL' -and
        ($boundaryResult.Output -join "`n") -match 'Unable to infer WorkspaceRoot') {
        Add-Check 'harness.ps1 does not cross its RepoRoot boundary to select an installed parent workspace'
    } else {
        Add-Failure 'harness.ps1 should fail closed instead of selecting an installed workspace above RepoRoot'
    }

    if (@(Compare-Object $parentAssistantBefore $parentAssistantAfter).Count -eq 0 -and
        $parentAgentsBefore -eq $parentAgentsAfter -and
        @(Compare-Object $nestedRepoBefore $nestedRepoAfter).Count -eq 0) {
        Add-Check 'RepoRoot boundary failure changes neither the installed parent nor the Harness source repo'
    } else {
        Add-Failure 'RepoRoot boundary failure should leave the installed parent and Harness source repo unchanged'
    }
}
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
