[CmdletBinding()]
param(
    [string]$WorkflowName = 'harness-lite',

    [Parameter(Mandatory = $true)]
    [string]$TaskId,

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

function Invoke-PowerShellFile {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('spawn-team-streams-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
    $stdoutPath = Join-Path $streamRoot 'stdout.txt'
    $stderrPath = Join-Path $streamRoot 'stderr.txt'
    $shellPath = (Get-Process -Id $PID).Path

    try {
        $process = Start-Process -FilePath $shellPath -ArgumentList (@('-NoProfile', '-File', $ScriptPath) + $Arguments) -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = if ($null -eq $stdout) { '' } else { $stdout.Trim() }
            StdErr = if ($null -eq $stderr) { '' } else { $stderr.Trim() }
        }
    } finally {
        Remove-Item -LiteralPath $streamRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-Result {
    param(
        [bool]$Ok,
        [string]$Reason,
        [string[]]$SpawnedRoles = @(),
        [string]$FailedRole = '',
        [string[]]$Errors = @()
    )

    return [ordered]@{
        ok = $Ok
        reason = $Reason
        task_id = $TaskId
        workflow = $WorkflowName
        spawned_roles = @($SpawnedRoles)
        failed_role = $FailedRole
        errors = @($Errors)
    }
}

$result = $null
$exitCode = 0
$presetTempPath = ''
try {
    if ($env:AIONUI_TEAM_MODE -ne '1') {
        $message = 'AIONUI_TEAM_MODE not set; team-mode is opt-in only'
        Write-Diagnostic $message
        $result = New-Result -Ok $false -Reason 'team_mode_disabled' -Errors @($message)
        $exitCode = 1
    } else {
        $spawnCommand = Get-Command -Name 'team_spawn_agent' -ErrorAction SilentlyContinue
        if ($null -eq $spawnCommand) {
            $message = 'team mode requested but team_spawn_agent unavailable; reverting to single-agent flow'
            Write-Diagnostic $message
            $result = New-Result -Ok $false -Reason 'mcp_unavailable' -Errors @($message)
            $exitCode = 1
        } else {
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

            $preset = Get-Content -LiteralPath $presetTempPath -Raw -Encoding utf8 | ConvertFrom-Json
            $spawnedRoles = New-Object System.Collections.Generic.List[string]
            foreach ($member in @($preset.members)) {
                $rolePromptPath = Join-Path $RepoRoot (([string]$member.role_prompt_ref) -replace '/', '\')
                if (-not (Test-Path -LiteralPath $rolePromptPath -PathType Leaf)) {
                    throw ("Missing role prompt for role {0}: {1}" -f $member.role, $rolePromptPath)
                }

                $payload = [ordered]@{
                    task_id = $TaskId
                    workflow = $WorkflowName
                    role = [string]$member.role
                    backend = [string]$member.backend
                    model = [string]$member.model
                    system_prompt = Get-Content -LiteralPath $rolePromptPath -Raw -Encoding utf8
                    skills_whitelist = @($member.skills_whitelist)
                    members_read_only_path_prefixes = @($preset.single_writer.members_read_only_path_prefixes)
                }

                try {
                    $null = team_spawn_agent -PayloadJson ($payload | ConvertTo-Json -Compress -Depth 8)
                    $spawnedRoles.Add([string]$member.role)
                } catch {
                    $message = ("team mode requested but team_spawn_agent failed for role {0}; reverting to single-agent flow: {1}" -f $member.role, $_.Exception.Message)
                    Write-Diagnostic $message
                    $result = New-Result -Ok $false -Reason 'spawn_failed' -SpawnedRoles @($spawnedRoles) -FailedRole ([string]$member.role) -Errors @($message)
                    $exitCode = 1
                    break
                }
            }

            if ($null -eq $result) {
                $result = New-Result -Ok $true -Reason 'spawned' -SpawnedRoles @($spawnedRoles)
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
