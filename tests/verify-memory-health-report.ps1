[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$runtimeDirName = Convert-CodePointsToString @(36816, 34892, 26102)
$memoryHealthReportFileName = ((Convert-CodePointsToString @(35760, 24518, 20307, 26816, 25253, 21578)) + '.md')
$scratchRoot = Join-Path $RepoRoot ('tmp\memory-health-report-regression-' + [guid]::NewGuid().ToString('N'))

try {
New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$healthyCaseRoot = Join-Path $scratchRoot 'fresh-v2-history-not-applicable'
$healthyWorkspace = Join-Path $healthyCaseRoot 'workspace'
$healthyUser = Join-Path $healthyCaseRoot 'user'
New-Item -ItemType Directory -Path $healthyWorkspace,$healthyUser -Force | Out-Null

$installResult = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $healthyWorkspace
    RepoRoot      = $RepoRoot
    VaultProfile  = 'full'
}
if ($installResult.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before memory-health-report smoke runs'
} else {
    Add-Check 'install.ps1 succeeds before memory-health-report smoke runs'
}

$healthyReportPath = Join-Path $healthyWorkspace 'reports\health\memory-health.md'
$healthyReportResult = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health-report.ps1') -Arguments @{
    OutputPath = $healthyReportPath
} -WorkingDirectory $healthyWorkspace
$healthyReportOutput = $healthyReportResult.Output -join [Environment]::NewLine
$healthyReportContent = if (Test-Path -LiteralPath $healthyReportPath -PathType Leaf) {
    Get-Content -LiteralPath $healthyReportPath -Raw -Encoding utf8
} else {
    ''
}

if ($healthyReportResult.ExitCode -ne 0) {
    Add-Failure 'memory-health-report.ps1 should complete for a fresh v2 workspace without requiring v1 mirrors'
} else {
    Add-Check 'memory-health-report.ps1 completes for a fresh v2 workspace without requiring v1 mirrors'
}

if ($healthyReportOutput -notmatch '(?im)^STATUS:\s+NOT_APPLICABLE\s*$' -or $healthyReportContent -notmatch '- \*\*status\*\*: NOT_APPLICABLE') {
    Add-Failure 'memory-health-report.ps1 must propagate NOT_APPLICABLE rather than label fresh v2 history checks PASS'
} else {
    Add-Check 'memory-health-report.ps1 propagates historical NOT_APPLICABLE into stdout and report'
}

if (-not (Test-Path -LiteralPath $healthyReportPath -PathType Leaf)) {
    Add-Failure 'memory-health-report.ps1 should create missing parent directories for a custom OutputPath'
} else {
    Add-Check 'memory-health-report.ps1 creates missing parent directories for a custom OutputPath'
}

if ($healthyReportContent -notmatch [regex]::Escape('## Raw Output')) {
    Add-Failure 'memory-health-report.ps1 should write the generated report content to the custom OutputPath'
} else {
    Add-Check 'memory-health-report.ps1 writes the generated report content to the custom OutputPath'
}

$healthyVault = Join-Path $healthyWorkspace '.assistant'
$healthResult = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/memory-health.ps1') -Arguments @{VaultRoot=$healthyVault}
$healthOutput = $healthResult.Output -join "`n"
if ($healthResult.ExitCode -eq 0 -and $healthOutput -match '^STATUS: NOT_APPLICABLE' -and $healthOutput -notmatch 'Shared memory is healthy|after repair|(?m)^STATUS: PASS') {
    Add-Check 'health wrapper preserves NOT_APPLICABLE without claiming health or advising lifecycle repair'
} else { Add-Failure 'health wrapper must preserve the historical not-applicable boundary' }
$layersResult = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/check-shared-memory-layers.ps1') -Arguments @{VaultRoot=$healthyVault;RepoRoot=$RepoRoot;Json=$true}
$layers = ($layersResult.Output -join "`n") | ConvertFrom-Json
if ($layersResult.ExitCode -eq 0 -and $layers.status -ceq 'NOT_APPLICABLE' -and $layers.scope -ceq 'historical-v1-only') {
    Add-Check 'layer diagnostic does not require v1 mirror reconstruction in a fresh v2 workspace'
} else { Add-Failure 'layer diagnostic must distinguish fresh v2 from historical health' }

$invalidMarker = Join-Path $healthyVault '运行时/当前任务.md'
[void][IO.Directory]::CreateDirectory($invalidMarker)
try {
    $invalid = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/memory-health.ps1') -Arguments @{VaultRoot=$healthyVault}
    $invalidLayers = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/check-shared-memory-layers.ps1') -Arguments @{VaultRoot=$healthyVault;RepoRoot=$RepoRoot;Json=$true}
    if ($invalid.ExitCode -eq 2 -and ($invalid.Output -join "`n") -match '^STATUS: FAIL' -and $invalidLayers.ExitCode -eq 1) {
        Add-Check 'wrong-type historical marker fails both diagnostics instead of appearing absent'
    } else { Add-Failure 'wrong-type history must fail closed' }
} finally { [IO.Directory]::Delete($invalidMarker) }
$missingFlow = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/memory-health.ps1') -Arguments @{VaultRoot=$healthyVault;OrchestratorFlowPath=(Join-Path $healthyWorkspace 'missing-flow.md')}
if ($missingFlow.ExitCode -eq 2 -and ($missingFlow.Output -join "`n") -match '^STATUS: FAIL') {
    Add-Check 'explicit missing flow cannot become a not-applicable success'
} else { Add-Failure 'explicit missing historical input must fail closed' }

$linkTarget = Join-Path $healthyWorkspace 'history-link-target'
$linkPath = Join-Path $healthyVault 'orchestration'
[void][IO.Directory]::CreateDirectory($linkTarget)
New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $linkPath -Target $linkTarget -ErrorAction Stop | Out-Null
try {
    $linked = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/memory-health.ps1') -Arguments @{VaultRoot=$healthyVault}
    if ($linked.ExitCode -eq 2 -and ($linked.Output -join "`n") -match '^STATUS: FAIL') { Add-Check 'reparse historical parent is rejected before a child lookup' }
    else { Add-Failure 'historical reparse parent must fail closed' }
} finally { Remove-Item -LiteralPath $linkPath -Force }

# A flow-only invocation must validate all ancestors before deriving its Vault.
$flowTarget = Join-Path $linkTarget 'current-flow.md'
[IO.File]::WriteAllText($flowTarget,('shared_vault_root: '+$healthyVault),[Text.UTF8Encoding]::new($false))
$flowAlias = Join-Path $healthyWorkspace 'flow-alias'
New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $flowAlias -Target $linkTarget -ErrorAction Stop | Out-Null
$flowLock = [IO.File]::Open($flowTarget,'Open','ReadWrite','None')
try {
    foreach ($relative in @('scripts/memory-health.ps1','scripts/memory-health-report.ps1','skills/obsidian-memory/scripts/run-memory-health.ps1','skills/obsidian-memory/scripts/write-memory-health-report.ps1')) {
        $handle = Start-RepoProcess -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot $relative) -Arguments @('-OrchestratorFlowPath',(Join-Path $flowAlias 'current-flow.md')) -WorkingDirectory $healthyWorkspace
        try {
            if (-not $handle.Process.WaitForExit(30000)) { $handle.Process.Kill($true); throw 'historical boundary fixture timed out' }
            $output = $handle.StdOut.GetAwaiter().GetResult()
            $errorOutput = $handle.StdErr.GetAwaiter().GetResult()
            if ($handle.Process.ExitCode -ne 0 -and $errorOutput -match 'legacy-history-path-invalid' -and $output -notmatch 'STATUS: NOT_APPLICABLE') {
                Add-Check "$relative rejects a reparse flow ancestor before reading its locked contents"
            } else { Add-Failure "$relative must preflight flow-only paths before reading history" }
        } finally { $handle.Process.Dispose() }
    }
} finally { $flowLock.Dispose(); Remove-Item -LiteralPath $flowAlias -Force }
if (-not (Test-Path -LiteralPath (Join-Path $healthyVault '运行时/记忆体检报告.md'))) { Add-Check 'rejected flow-only reports create no implicit report output' }
else { Add-Failure 'rejected flow-only report wrote output before path validation' }

foreach ($linkedParent in @('工作流','配置')) {
    $assetCase = Join-Path $scratchRoot ('linked-assets-'+$linkedParent)
    $assetVault = Join-Path $assetCase '.assistant'
    $assetTarget = Join-Path $assetCase 'linked-target'
    [void][IO.Directory]::CreateDirectory($assetTarget)
    foreach ($relative in @('工作流/共享记忆协议.md','工作流/记忆管理协议.md','运行时/收件箱.md','运行时/记忆候选.md','配置/系统信息.md','配置/用户偏好.md','配置/工具与组件.md')) {
        $assetPath = if ($relative.StartsWith($linkedParent+'/')) { Join-Path $assetTarget (Split-Path -Leaf $relative) } else { Join-Path $assetVault $relative }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $assetPath))
        [IO.File]::WriteAllText($assetPath,'ordinary optional Memory fixture',[Text.UTF8Encoding]::new($false))
    }
    $assetLink = Join-Path $assetVault $linkedParent
    New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $assetLink -Target $assetTarget -ErrorAction Stop | Out-Null
    try {
        $linkedAssets = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/memory-health.ps1') -Arguments @{VaultRoot=$assetVault}
        if ($linkedAssets.ExitCode -eq 2 -and ($linkedAssets.Output -join "`n") -match '^STATUS: FAIL') { Add-Check "$linkedParent reparse parent cannot make ordinary leaves a valid fresh Memory boundary" }
        else { Add-Failure "$linkedParent reparse parent must fail closed before the leaf check" }
    } finally { Remove-Item -LiteralPath $assetLink -Force }
}

# Explicitly seed preserved historical templates for the historical PASS case.
# No retired installer, repair, stage writer, or actual workspace state is used.
. (Join-Path $RepoRoot 'skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1')
$literalFlow = Join-Path $healthyWorkspace 'flow[1].md'
$neighborFlow = Join-Path $healthyWorkspace 'flow1.md'
[IO.File]::WriteAllText($literalFlow,('shared_vault_root: '+$healthyVault),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($neighborFlow,'shared_vault_root: wrong-neighbor',[Text.UTF8Encoding]::new($false))
$neighborLock = [IO.File]::Open($neighborFlow,'Open','ReadWrite','None')
try {
    if ((Get-FlowSharedVaultRoot -OrchestratorFlowPath $literalFlow) -ceq $healthyVault) { Add-Check 'flow content reads the validated literal path, not a wildcard-expanded locked neighbor' }
    else { Add-Failure 'flow content read did not bind the literal validated path' }
} finally { $neighborLock.Dispose() }

$historyPaths = @()
foreach ($relative in @('运行时/当前任务.md','运行时/恢复索引.md','运行时/中断任务.md','运行时/上次会话.md','工作流/写回协议.md','工作流/恢复协议.md')) {
    $source = Join-Path $RepoRoot ('vault-template/' + $relative + $(if($relative.StartsWith('运行时/')){'.template'}else{''}))
    $target = Join-Path $healthyVault $relative
    $content = [IO.File]::ReadAllText($source).Replace('__RENDER_AT_INSTALL__','2026-08-31').Replace('__RUNTIME_TIMESTAMP__','2026-08-31T12:00:00+08:00')
    [IO.File]::WriteAllText($target,$content,[Text.UTF8Encoding]::new($true))
    $historyPaths += $target
}
[void][IO.Directory]::CreateDirectory((Join-Path $healthyVault '运行时/tasks'))
$beforeHistory = @($historyPaths | ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}) -join '|'
$historicalPath = Join-Path $healthyWorkspace 'reports/history.md'
$historical = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts/memory-health-report.ps1') -Arguments @{VaultRoot=$healthyVault;OutputPath=$historicalPath}
$afterHistory = @($historyPaths | ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}) -join '|'
if ($historical.ExitCode -eq 0 -and ($historical.Output -join "`n") -match '^STATUS: PASS' -and $beforeHistory -ceq $afterHistory -and
    ([IO.File]::ReadAllText($historicalPath) -match 'historical-v1-only; not current v2 Runtime health')) {
    Add-Check 'explicit historical report retains PASS propagation and preserves all historical bytes'
} else { Add-Failure 'historical report must preserve its read-only scope and status propagation' }

$failingCaseRoot = Join-Path $scratchRoot 'failing-vault-status'
$failingVaultRoot = Join-Path $failingCaseRoot '.assistant'
New-Item -ItemType Directory -Path (Join-Path $failingVaultRoot $runtimeDirName) -Force | Out-Null
$failingUser = Join-Path $failingCaseRoot 'user'
New-Item -ItemType Directory -Path $failingUser -Force | Out-Null

$failingReportResult = Invoke-RepoScript -UserProfile $failingUser -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health-report.ps1') -Arguments @{
    VaultRoot = $failingVaultRoot
}
$failingReportOutput = $failingReportResult.Output -join [Environment]::NewLine
$failingReportPath = Join-Path (Join-Path $failingVaultRoot $runtimeDirName) $memoryHealthReportFileName
$failingReportContent = if (Test-Path -LiteralPath $failingReportPath -PathType Leaf) {
    Get-Content -LiteralPath $failingReportPath -Raw -Encoding utf8
} else {
    ''
}

if ($failingReportResult.ExitCode -ne 2) {
    Add-Failure 'memory-health-report.ps1 should propagate a failing checker exit code when shared memory is invalid'
} else {
    Add-Check 'memory-health-report.ps1 propagates a failing checker exit code when shared memory is invalid'
}

if ($failingReportOutput -notmatch '(?im)^STATUS:\s+FAIL\s*$') {
    Add-Failure 'memory-health-report.ps1 should report STATUS: FAIL when check-shared-memory.ps1 fails'
} else {
    Add-Check 'memory-health-report.ps1 reports STATUS: FAIL when check-shared-memory.ps1 fails'
}

if ($failingReportOutput -notmatch '(?im)^SourceExitCode:\s+2\s*$') {
    Add-Failure 'memory-health-report.ps1 should report the checker exit code in its output'
} else {
    Add-Check 'memory-health-report.ps1 reports the checker exit code in its output'
}

if (-not (Test-Path -LiteralPath $failingReportPath -PathType Leaf)) {
    Add-Failure 'memory-health-report.ps1 should still write a report file when the checker fails'
} else {
    Add-Check 'memory-health-report.ps1 still writes a report file when the checker fails'
}

if ($failingReportContent -notmatch [regex]::Escape('- **status**: FAIL')) {
    Add-Failure 'memory-health-report.ps1 should persist the failing checker status into the generated report'
} else {
    Add-Check 'memory-health-report.ps1 persists the failing checker status into the generated report'
}

if ((Test-FileHasUtf8Bom -Path $healthyReportPath) -and (Test-FileHasUtf8Bom -Path $failingReportPath) -and (Test-FileHasUtf8Bom -Path $historicalPath)) {
    Add-Check 'memory-health-report.ps1 writes not-applicable, historical PASS, and failing reports as UTF-8 with BOM'
} else {
    Add-Failure 'memory-health-report.ps1 should preserve report encoding for every status'
}
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ('- {0}' -f $item)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ('- {0}' -f $failure)
}

exit 1
