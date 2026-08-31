Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Explicit maintenance boundary. Ordinary Protocol/Policy/status must not import this module.
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'scripts/lib/Harness.AtomicWrite.psm1') -Force
Import-Module (Join-Path $repo 'scripts/lib/Harness.Path.psm1') -Force

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


function Get-HarnessLegacyMigrationSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId)
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    Assert-HarnessTaskId -TaskId $TaskId
    $task = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ".assistant/runtime/tasks/$TaskId/task.json" -Label 'migration target' -AllowMissing
    if (Test-Path -LiteralPath $task) { throw 'migration requires an existing v1 task; a v2 target already exists' }
    $relative = "docs/tasks/$TaskId/plan.md"
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $relative -Label 'v1 migration source' -MustExist File
    $content = [IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))
    $fields = Get-HarnessV1Frontmatter -Content $content
    Assert-HarnessV1Frontmatter -Fields $fields -TaskId $TaskId
    return [ordered]@{detected_protocol='v1';v1_stage=[string]$fields.stage;v1_plan_path=$relative;v1_plan_digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $relative)}
}

Export-ModuleMember -Function Get-HarnessLegacyMigrationSource
