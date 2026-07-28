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
    if (-not $Handle.Process.WaitForExit(90000)) { $Handle.Process.Kill($true); throw 'protocol fixture process timeout' }
    $result = [pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()}
    $Handle.Process.Dispose()
    return $result
}
function Invoke-Cli($Workspace,[string[]]$Arguments,[AllowNull()][string]$Protocol) {
    $priorProtocol = [Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[EnvironmentVariableTarget]::Process)
    $priorReport = [Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process)
    try {
        if ($null -eq $Protocol) { Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore } else { $env:HARNESS_PROTOCOL = $Protocol }
        Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction Ignore
        return Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $script:taskScript -Arguments (@($Arguments) + @('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$Workspace,'-AsJson')))
    } finally {
        if ($null -eq $priorProtocol) { Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore } else { $env:HARNESS_PROTOCOL = $priorProtocol }
        if ($null -eq $priorReport) { Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction Ignore } else { $env:HARNESS_V2_ELIGIBILITY_REPORT = $priorReport }
    }
}
function Read-Json($Result) { if ($Result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($Result.StdOut)) { return $null }; return $Result.StdOut | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String }
function Snapshot($Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Force -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\','/')
        if ($_.PSIsContainer) { "D|$relative" } else { "F|$relative|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    } | Sort-Object)
}
function Same($Before,$After,[string]$Pass,[string]$Fail) { Check ((@($Before) -join "`n") -ceq (@($After) -join "`n")) $Pass $Fail }
function Test-SchemaRejected([string]$Json,[string]$SchemaPath) {
    try { return -not (Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction Stop -WarningAction SilentlyContinue) } catch { return $true }
}
function Write-ConfigBytes($Workspace,[byte[]]$Bytes) {
    $path = Join-Path $Workspace '.assistant\config\protocol.json'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [System.IO.File]::WriteAllBytes($path,$Bytes)
    return $path
}
function New-V2TaskDocument($TaskId) {
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    return [ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='ready';identity='existing';intent='write';requirement_state='clear';execution_profile='direct';persistence='ephemeral';policies=[ordered]@{plan_required=$false;approval_required=$false;rollback_required=$false;independent_review_required=$false;verification_required=$true};created_at=$now;updated_at=$now}
}

$script:taskScript = Join-Path $RepoRoot 'scripts\task.ps1'
$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1'
$schemaPath = Join-Path $RepoRoot 'schemas\protocol-config.schema.json'
$repoBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('v2-protocol-config-'+[guid]::NewGuid().ToString('N'))
$workspace = Join-Path $temp 'workspace'
$configJunction = $null
try {
    [void][System.IO.Directory]::CreateDirectory($workspace)
    foreach ($file in @($modulePath,$script:taskScript,$PSCommandPath)) {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors) | Out-Null
        Check (@($errors).Count -eq 0) "$(Split-Path -Leaf $file) parses" "$(Split-Path -Leaf $file) parse failed"
        Check (Test-FileHasUtf8Bom $file) "$(Split-Path -Leaf $file) has UTF-8 BOM" "$(Split-Path -Leaf $file) lacks UTF-8 BOM"
    }
    $module = Import-Module $modulePath -Force -PassThru
    $exports = @($module.ExportedFunctions.Keys | Sort-Object)
    Check (@(Compare-Object $exports @('Get-HarnessProtocolResolution','Get-HarnessWorkspaceProtocolConfig','Set-HarnessWorkspaceProtocolConfig')).Count -eq 0) 'Protocol exports only resolution and workspace config operations' 'Protocol export surface is invalid'
    $validJson = '{"schema_version":"harness-protocol-config/v1","new_task_protocol":"v2"}'
    Check (Test-Json -Json $validJson -SchemaFile $schemaPath -ErrorAction Stop) 'protocol config schema accepts the public v1 shape' 'protocol config schema rejected its public v1 shape'
    Check (Test-SchemaRejected -Json '{"schema_version":"harness-protocol-config/v1","new_task_protocol":"v3"}' -SchemaPath $schemaPath) 'protocol config schema rejects unknown protocol values' 'protocol config schema accepted an unknown protocol value'

    $missingBefore = Snapshot $workspace
    $missingResult = Invoke-Cli $workspace @('protocol') $null
    $missing = Read-Json $missingResult
    Check ($missingResult.ExitCode -eq 0 -and $missing.selected_protocol -ceq 'v1' -and $missing.preference_source -ceq 'default-auto' -and $missing.workspace_config.status -ceq 'missing' -and $missing.side_effects.runtime_writes -eq 0) 'protocol status defaults a new task to v1 without a local selection or Runtime Default' 'protocol status did not preserve the v1 fallback'
    Same $missingBefore (Snapshot $workspace) 'protocol status is read-only' 'protocol status wrote workspace state'

    $enableResult = Invoke-Cli $workspace @('enable-v2') $null
    $enable = Read-Json $enableResult
    $configPath = Join-Path $workspace '.assistant\config\protocol.json'
    $configBytes = [System.IO.File]::ReadAllBytes($configPath)
    $configText = [System.Text.UTF8Encoding]::new($false,$true).GetString($configBytes)
    $configDocument = $configText | ConvertFrom-Json -AsHashtable -DateKind String
    $debris = @(Get-ChildItem -LiteralPath (Split-Path -Parent $configPath) -Force | Where-Object { $_.Name -like '.protocol.json.*.tmp*' })
    Check ($enableResult.ExitCode -eq 0 -and $enable.new_task_protocol -ceq 'v2' -and $enable.side_effects.config_writes -eq 1 -and $enable.side_effects.runtime_writes -eq 0) 'enable-v2 reports one contained config write and no runtime write' 'enable-v2 reported the wrong write surface'
    Check ($configBytes.Length -gt 0 -and -not ($configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF) -and [string]$configDocument.schema_version -ceq 'harness-protocol-config/v1' -and [string]$configDocument.new_task_protocol -ceq 'v2' -and $debris.Count -eq 0) 'enable-v2 writes strict BOM-less UTF-8 atomically without debris' 'enable-v2 encoding or atomicity is invalid'

    $reopenResult = Invoke-Cli $workspace @('protocol') $null
    $reopen = Read-Json $reopenResult
    Check ($reopenResult.ExitCode -eq 0 -and $reopen.selected_protocol -ceq 'v2' -and $reopen.preference_source -ceq 'workspace-config' -and $reopen.reason -ceq 'workspace-v2-new-task') 'a fresh process with no protocol environment variable honors workspace enable-v2' 'workspace enable-v2 did not survive a fresh process without environment state'
    $envRollback = Read-Json (Invoke-Cli $workspace @('protocol') 'v1')
    Check ($envRollback.selected_protocol -ceq 'v1' -and $envRollback.preference_source -ceq 'HARNESS_PROTOCOL' -and $envRollback.workspace_config.status -ceq 'not-read') 'HARNESS_PROTOCOL=v1 immediately overrides workspace enable-v2 for a new task' 'environment rollback did not outrank workspace config'

    $v1Id = 'artifact-v1'; $v1Path = Join-Path $workspace "docs\tasks\$v1Id\plan.md"
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $v1Path))
    [System.IO.File]::WriteAllText($v1Path,"---`ntask_id: $v1Id`nstage: PLAN`ntool: codex`nupdated: 2026-07-22`n---`n",[System.Text.UTF8Encoding]::new($false))
    $v1Artifact = Read-Json (Invoke-Cli $workspace @('protocol','-TaskId',$v1Id) 'v2')
    Check ($v1Artifact.detected_protocol -ceq 'v1' -and $v1Artifact.selected_protocol -ceq 'v1' -and $v1Artifact.preference_source -ceq 'existing-artifact' -and $v1Artifact.workspace_config.status -ceq 'not-read') 'existing v1 artifact outranks environment and workspace v2 selections' 'existing v1 artifact was overridden by a new-task preference'

    $disableResult = Invoke-Cli $workspace @('disable-v2') $null
    $disable = Read-Json $disableResult
    $v2Id = 'artifact-v2'; $v2Path = Join-Path $workspace ".assistant\runtime\tasks\$v2Id\task.json"
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $v2Path))
    [System.IO.File]::WriteAllText($v2Path,((New-V2TaskDocument $v2Id) | ConvertTo-Json -Depth 20 -Compress),[System.Text.UTF8Encoding]::new($false))
    $v2Artifact = Read-Json (Invoke-Cli $workspace @('protocol','-TaskId',$v2Id) 'v1')
    Check ($disableResult.ExitCode -eq 0 -and $disable.new_task_protocol -ceq 'v1') 'disable-v2 records the workspace v1 stop-loss' 'disable-v2 did not record v1'
    Check ($v2Artifact.detected_protocol -ceq 'v2' -and $v2Artifact.selected_protocol -ceq 'v2' -and $v2Artifact.preference_source -ceq 'existing-artifact' -and $v2Artifact.workspace_config.status -ceq 'not-read') 'existing v2 artifact outranks environment and workspace v1 selections' 'existing v2 artifact was downgraded by a new-task preference'

    $resetResult = Invoke-Cli $workspace @('reset-auto') $null
    $reset = Read-Json $resetResult
    $resetStatus = Read-Json (Invoke-Cli $workspace @('protocol') $null)
    Check ($resetResult.ExitCode -eq 0 -and $reset.new_task_protocol -ceq 'auto' -and $resetStatus.selected_protocol -ceq 'v1' -and $resetStatus.preference_source -ceq 'workspace-config' -and $resetStatus.reason -ceq 'runtime-default-missing') 'reset-auto restores Runtime Default lookup and therefore the current v1 fallback' 'reset-auto silently promoted new tasks to v2'

    $invalidCases = @(
        [pscustomobject]@{Name='BOM';Bytes=[byte[]](0xEF,0xBB,0xBF)+[System.Text.UTF8Encoding]::new($false).GetBytes($validJson)},
        [pscustomobject]@{Name='invalid UTF-8';Bytes=[byte[]](0xC3,0x28)},
        [pscustomobject]@{Name='duplicate key';Bytes=[System.Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":"harness-protocol-config/v1","new_task_protocol":"v1","new_task_protocol":"v2"}')},
        [pscustomobject]@{Name='unknown key';Bytes=[System.Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":"harness-protocol-config/v1","new_task_protocol":"v2","extra":true}')},
        [pscustomobject]@{Name='wrong schema';Bytes=[System.Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":"harness-protocol-config/v2","new_task_protocol":"v2"}')}
    )
    foreach ($invalid in $invalidCases) {
        [System.IO.File]::WriteAllBytes($configPath,$invalid.Bytes)
        $before = Snapshot $workspace
        $result = Invoke-Cli $workspace @('protocol') $null
        Check ($result.ExitCode -eq 2 -and [string]::IsNullOrWhiteSpace($result.StdOut) -and $result.StdErr -match 'workspace protocol config') "$($invalid.Name) config fails closed" "$($invalid.Name) config was accepted"
        Same $before (Snapshot $workspace) "$($invalid.Name) rejection is zero-write" "$($invalid.Name) rejection changed workspace state"
    }

    Remove-Item -LiteralPath (Join-Path $workspace '.assistant') -Recurse -Force
    [void][System.IO.Directory]::CreateDirectory((Join-Path $workspace '.assistant'))
    $outside = Join-Path $temp 'outside-config'; [void][System.IO.Directory]::CreateDirectory($outside)
    $outsideBefore = Snapshot $outside
    $configJunction = Join-Path $workspace '.assistant\config'
    New-Item -ItemType Junction -Path $configJunction -Target $outside | Out-Null
    $reparseResult = Invoke-Cli $workspace @('enable-v2') $null
    Check ($reparseResult.ExitCode -eq 2 -and $reparseResult.StdErr -match 'reparse point') 'enable-v2 rejects a reparse alias in the fixed config path' 'enable-v2 crossed a reparse alias'
    Same $outsideBefore (Snapshot $outside) 'reparse rejection writes nothing outside the workspace' 'reparse rejection wrote through the alias'
    [System.IO.Directory]::Delete($configJunction,$false); $configJunction = $null
} finally {
    Remove-Module Harness.Protocol -ErrorAction Ignore
    if ($null -ne $configJunction -and (Test-Path -LiteralPath $configJunction)) { try { [System.IO.Directory]::Delete($configJunction,$false) } catch {} }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
$repoAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Check ((@($repoBefore) -join "`n") -ceq (@($repoAfter) -join "`n")) 'protocol config verifier leaves repository state unchanged' 'protocol config verifier changed repository state'
foreach ($item in $script:checks) { "[PASS] $item" }
foreach ($item in $script:failures) { "[FAIL] $item" }
if ($script:failures.Count) { "STATUS: FAIL ($($script:failures.Count) failed)"; exit 1 }
"STATUS: PASS ($($script:checks.Count) checks)"
exit 0
