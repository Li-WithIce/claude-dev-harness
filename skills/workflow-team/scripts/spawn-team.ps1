[CmdletBinding()]
param(
    [string]$WorkflowName = 'harness-lite',

    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [ValidateSet('', 'PLAN', 'PLAN_REVIEW', 'IMPLEMENT', 'CODE_REVIEW', 'TEST', 'DONE')]
    [string]$Stage = '',

    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
} else {
    $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
}

function Write-Diagnostic {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        [Console]::Error.WriteLine($Message)
    }
}

function Write-TraceDiagnostic {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($env:HARNESS_SPAWN_TEAM_TRACE)) {
        [System.IO.File]::AppendAllText($env:HARNESS_SPAWN_TEAM_TRACE, ($Message + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Invoke-PowerShellFile {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    Write-TraceDiagnostic 'Invoke-PowerShellFile: begin'
    $shellPath = (Get-Process -Id $PID).Path
    $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $argumentText = ($allArguments | ForEach-Object {
            $value = [string]$_
            if ($value -notmatch '[\s"]') {
                $value
            } else {
                '"' + ($value -replace '"', '\"') + '"'
            }
        }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $shellPath
    $psi.Arguments = $argumentText
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    Write-TraceDiagnostic ('Invoke-PowerShellFile: shell={0}' -f $shellPath)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        Write-TraceDiagnostic 'Invoke-PowerShellFile: before start'
        $process.Start() | Out-Null
        Write-TraceDiagnostic 'Invoke-PowerShellFile: after start'
        $stdout = $process.StandardOutput.ReadToEnd()
        Write-TraceDiagnostic 'Invoke-PowerShellFile: stdout read'
        $stderr = $process.StandardError.ReadToEnd()
        Write-TraceDiagnostic 'Invoke-PowerShellFile: stderr read'
        $process.WaitForExit()
        Write-TraceDiagnostic ('Invoke-PowerShellFile: exit={0}' -f $process.ExitCode)

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = if ($null -eq $stdout) { '' } else { $stdout.Trim() }
            StdErr = if ($null -eq $stderr) { '' } else { $stderr.Trim() }
        }
    } finally {
        $process.Dispose()
    }
}

function New-Result {
    param(
        [bool]$Ok,
        [string]$Reason,
        [string]$Stage = '',
        [string[]]$SpawnedRoles = @(),
        [string]$FailedRole = '',
        [string[]]$Errors = @()
    )

    return [ordered]@{
        ok = $Ok
        reason = $Reason
        task_id = $TaskId
        workflow = $WorkflowName
        stage = $Stage
        spawned_roles = @($SpawnedRoles)
        failed_role = $FailedRole
        errors = @($Errors)
    }
}

function Resolve-ActiveStage {
    param(
        [string]$RequestedStage,
        [string]$RepoRoot,
        [string]$TaskId
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedStage)) {
        return $RequestedStage
    }

    $planPath = Join-Path $RepoRoot ('docs\tasks\{0}\plan.md' -f $TaskId)
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw "Team spawn requires -Stage or current plan.md: $planPath"
    }

    $match = Select-String -LiteralPath $planPath -Pattern '^stage:\s*(PLAN|PLAN_REVIEW|IMPLEMENT|CODE_REVIEW|TEST|DONE)\s*$' -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        throw "Unable to resolve legal stage from plan.md: $planPath"
    }

    return $match.Matches[0].Groups[1].Value
}

$result = $null
$exitCode = 0
$presetTempPath = ''
try {
    Write-TraceDiagnostic 'spawn-team: begin'
    if ($env:AITEAMCODE_TEAM_MODE -ne '1') {
        $message = 'AITEAMCODE_TEAM_MODE not set; team-mode is opt-in only'
        Write-Diagnostic $message
        $result = New-Result -Ok $false -Reason 'team_mode_disabled' -Errors @($message)
        $exitCode = 1
    } else {
        $activeStage = Resolve-ActiveStage -RequestedStage $Stage -RepoRoot $RepoRoot -TaskId $TaskId
        if ($activeStage -eq 'DONE') {
            $message = 'Team spawn is not available for DONE; no active stage role remains.'
            Write-Diagnostic $message
            $result = New-Result -Ok $false -Reason 'stage_complete' -Stage $activeStage -Errors @($message)
            $exitCode = 1
        }

        if ($null -eq $result) {
        Write-TraceDiagnostic 'spawn-team: before get-command'
        $spawnCommand = Get-Command -Name 'team_spawn_agent' -ErrorAction SilentlyContinue
        Write-TraceDiagnostic 'spawn-team: after get-command'
        if ($null -eq $spawnCommand) {
            $message = 'team mode requested but team_spawn_agent unavailable; reverting to single-agent flow'
            Write-Diagnostic $message
            $result = New-Result -Ok $false -Reason 'mcp_unavailable' -Errors @($message)
            $exitCode = 1
        } else {
            Write-TraceDiagnostic 'spawn-team: before export'
            $exportScriptPath = Join-Path $RepoRoot 'scripts\export-team-preset.ps1'
            if (-not (Test-Path -LiteralPath $exportScriptPath -PathType Leaf)) {
                throw ("Missing export-team-preset script: {0}" -f $exportScriptPath)
            }

            $presetTempPath = Join-Path ([System.IO.Path]::GetTempPath()) ('team-preset-' + [guid]::NewGuid().ToString('N') + '.json')
            $export = Invoke-PowerShellFile -ScriptPath $exportScriptPath -Arguments @(
                '-Workflow', $WorkflowName,
                '-Output', $presetTempPath,
                '-Format', 'json',
                '-RepoRoot', $RepoRoot
            )
            Write-TraceDiagnostic ('spawn-team: after export exit={0}' -f $export.ExitCode)
            if ($export.ExitCode -ne 0) {
                $message = if ([string]::IsNullOrWhiteSpace($export.StdErr)) {
                    'export-team-preset failed.'
                } else {
                    $export.StdErr
                }
                throw $message
            }

            if (-not [string]::IsNullOrWhiteSpace($export.StdErr)) {
                foreach ($line in ($export.StdErr -split "\r?\n")) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        Write-Diagnostic $line
                    }
                }
            }

            if (-not (Test-Path -LiteralPath $presetTempPath -PathType Leaf)) {
                throw ("export-team-preset did not create preset file: {0}" -f $presetTempPath)
            }

            Write-TraceDiagnostic 'spawn-team: before preset read'
            $preset = Get-Content -LiteralPath $presetTempPath -Raw -Encoding utf8 | ConvertFrom-Json
            Write-TraceDiagnostic 'spawn-team: after preset read'
            $stageMembers = @($preset.members | Where-Object { [string]$_.stage -eq $activeStage })
            if ($stageMembers.Count -ne 1) {
                throw ('Preset should contain exactly one member for stage {0}; got {1}' -f $activeStage, $stageMembers.Count)
            }

            $spawnedRoles = New-Object System.Collections.Generic.List[string]
            foreach ($member in $stageMembers) {
                Write-TraceDiagnostic ('spawn-team: member {0} begin' -f $member.role)
                $rolePromptPath = Join-Path $RepoRoot (([string]$member.role_prompt_ref) -replace '/', '\')
                if (-not (Test-Path -LiteralPath $rolePromptPath -PathType Leaf)) {
                    throw ("Missing role prompt for role {0}: {1}" -f $member.role, $rolePromptPath)
                }

                Write-TraceDiagnostic ('spawn-team: member {0} before prompt' -f $member.role)
                $systemPrompt = Get-Content -LiteralPath $rolePromptPath -Raw -Encoding utf8
                Write-TraceDiagnostic ('spawn-team: member {0} after prompt' -f $member.role)
                $skillsWhitelist = @($member.skills_whitelist | ForEach-Object { [string]$_ })
                $readOnlyPrefixes = @($preset.single_writer.members_read_only_path_prefixes | ForEach-Object { [string]$_ })
                $payload = [pscustomobject][ordered]@{
                    task_id = $TaskId
                    workflow = $WorkflowName
                    stage = $activeStage
                    role = [string]$member.role
                    backend = [string]$member.backend
                    model = [string]$member.model
                    system_prompt = $systemPrompt
                    skills_whitelist = $skillsWhitelist
                    members_read_only_path_prefixes = $readOnlyPrefixes
                }

                try {
                    Write-TraceDiagnostic ('spawn-team: member {0} before payload json' -f $member.role)
                    $payloadJson = $payload | ConvertTo-Json -Compress -Depth 8
                    Write-TraceDiagnostic ('spawn-team: member {0} before spawn call' -f $member.role)
                    $null = team_spawn_agent -PayloadJson $payloadJson
                    Write-TraceDiagnostic ('spawn-team: member {0} after spawn call' -f $member.role)
                    $spawnedRoles.Add([string]$member.role)
                } catch {
                    $message = ("team mode requested but team_spawn_agent failed for role {0}; reverting to single-agent flow: {1}" -f $member.role, $_.Exception.Message)
                    Write-Diagnostic $message
                    $result = New-Result -Ok $false -Reason 'spawn_failed' -Stage $activeStage -SpawnedRoles @($spawnedRoles) -FailedRole ([string]$member.role) -Errors @($message)
                    $exitCode = 1
                    break
                }
            }

            if ($null -eq $result) {
                $result = New-Result -Ok $true -Reason 'spawned' -Stage $activeStage -SpawnedRoles @($spawnedRoles)
            }
        }
    }
    }
} catch {
    Write-Diagnostic $_.Exception.Message
    if ($null -eq $result) {
        $result = New-Result -Ok $false -Reason 'spawn_failed' -Errors @($_.Exception.Message)
        $exitCode = 1
    }
} finally {
    if (-not [string]::IsNullOrWhiteSpace($presetTempPath) -and (Test-Path -LiteralPath $presetTempPath -PathType Leaf)) {
        Remove-Item -LiteralPath $presetTempPath -Force -ErrorAction SilentlyContinue
    }
}

[Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 8))
exit $exitCode
