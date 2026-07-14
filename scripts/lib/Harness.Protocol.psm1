Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop

function Get-HarnessV1Frontmatter {
    param([Parameter(Mandatory)][string]$Content)

    $match = [regex]::Match($Content,'\A---\r?\n(?<body>.*?)\r?\n---\r?\n',[System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'v1 plan is missing frontmatter' }
    $fields = [ordered]@{}
    foreach ($line in ($match.Groups['body'].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -cnotmatch '^([a-z_]+):\s*(.+)$') { throw "v1 plan has an invalid frontmatter line: $line" }
        $key = [string]$Matches[1]
        if ($fields.Contains($key)) { throw "v1 plan has a duplicate frontmatter field: $key" }
        $fields[$key] = $Matches[2].Trim()
    }
    return $fields
}

function Assert-HarnessV1Frontmatter {
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Fields,
        [Parameter(Mandatory)][string]$TaskId
    )

    $required = @('task_id','stage','tool','updated')
    $optional = @('tool_profile','model')
    $actual = @($Fields.Keys | ForEach-Object { [string]$_ })
    $unknown = @($actual | Where-Object { $_ -cnotin @($required + $optional) })
    $requiredInOrder = @($actual | Where-Object { $_ -cin $required })
    if ($unknown.Count -gt 0 -or ($requiredInOrder -join '|') -cne ($required -join '|')) {
        throw 'v1 plan frontmatter field set or order is invalid'
    }
    $toolIndex = [array]::IndexOf($actual,'tool')
    $updatedIndex = [array]::IndexOf($actual,'updated')
    foreach ($name in $optional) {
        $index = [array]::IndexOf($actual,$name)
        if ($index -ge 0 -and ($index -le $toolIndex -or $index -ge $updatedIndex)) {
            throw "v1 plan optional frontmatter field is out of order: $name"
        }
    }
    if ([string]$Fields['task_id'] -cne $TaskId) { throw 'v1 plan task_id does not match TaskId' }
    $stage = [string]$Fields['stage']
    if ($stage -cnotin @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')) { throw 'v1 plan stage is invalid' }
    if ($stage -ceq 'DONE') {
        if ([string]$Fields['tool'] -cne 'none') { throw 'v1 DONE plan requires tool: none' }
    } elseif ([string]$Fields['tool'] -cnotin @('claudecode','codex')) {
        throw 'v1 plan tool is invalid'
    }
    if ([string]$Fields['updated'] -cnotmatch '^\d{4}-\d{2}-\d{2}$') { throw 'v1 plan updated date is invalid' }
}

function Get-HarnessProtocolResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$TaskId = '',
        [string]$RequestedProtocol = ''
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Assert-HarnessTaskId -TaskId $TaskId }
    $requested = $RequestedProtocol
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = [System.Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[System.EnvironmentVariableTarget]::Process)
    }
    if ([string]::IsNullOrWhiteSpace($requested)) { $requested = 'auto' }
    if ($requested -cnotin @('auto','v1','v2')) { throw 'HARNESS_PROTOCOL must be auto, v1, or v2' }

    $detected = 'new'
    $stage = $null
    $planPath = $null
    $planDigest = $null
    $taskStatePath = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $taskStatePath = ".assistant/runtime/tasks/$TaskId/task.json"
        $taskStateTarget = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $taskStatePath -Label 'v2 task state' -AllowMissing
        if (Test-Path -LiteralPath $taskStateTarget) {
            if (-not (Test-Path -LiteralPath $taskStateTarget -PathType Leaf)) { throw 'v2 task state path is not a file' }
            $detected = 'v2'
        } else {
            $planPath = "docs/tasks/$TaskId/plan.md"
            $planTarget = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $planPath -Label 'v1 plan' -AllowMissing
            if (Test-Path -LiteralPath $planTarget) {
                if (-not (Test-Path -LiteralPath $planTarget -PathType Leaf)) { throw 'v1 plan path is not a file' }
                try {
                    $content = [System.IO.File]::ReadAllText($planTarget,[System.Text.UTF8Encoding]::new($false,$true))
                    $fields = Get-HarnessV1Frontmatter -Content $content
                    Assert-HarnessV1Frontmatter -Fields $fields -TaskId $TaskId
                } catch {
                    throw "v1 plan exists but is not a legal v1 artifact: $($_.Exception.Message)"
                }
                $detected = 'v1'
                $stage = [string]$fields['stage']
                $planDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $planPath
            }
        }
    }

    if ($detected -ceq 'v1' -and $requested -ceq 'v2') {
        throw 'existing v1 task cannot be forced to v2; run the explicit v1-to-v2 migration command'
    }
    if ($detected -ceq 'v2' -and $requested -ceq 'v1') {
        throw 'existing v2 task cannot use the v1 compatibility path'
    }

    $selected = if ($detected -cin @('v1','v2')) {
        $detected
    } elseif ($requested -ceq 'v2') {
        'v2'
    } else {
        'v1'
    }
    $reason = if ($detected -ceq 'v2') {
        'existing-v2-task-state'
    } elseif ($detected -ceq 'v1') {
        'existing-v1-plan'
    } elseif ($requested -ceq 'v2') {
        'explicit-v2-new-task'
    } else {
        'pr12-new-task-default-v1'
    }

    return [ordered]@{
        operation='protocol'
        task_id=$(if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId })
        requested_protocol=$requested
        detected_protocol=$detected
        selected_protocol=$selected
        reason=$reason
        v1_stage=$stage
        v1_plan_path=$(if ($detected -ceq 'v1') { $planPath } else { $null })
        v1_plan_digest=$planDigest
        v2_task_state_path=$(if ($detected -ceq 'v2') { $taskStatePath } else { $null })
        side_effects=[ordered]@{runtime_writes=0;artifact_writes=0}
    }
}

Export-ModuleMember -Function Get-HarnessProtocolResolution
