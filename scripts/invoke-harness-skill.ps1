[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [string]$Skill,

    [Parameter(Mandatory = $true)]
    [string]$Tool,

    [string]$ToolProfileId = "",

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [ValidateSet('readonly', 'writable')]
    [string]$Mode = 'readonly',

    [string]$PayloadJson = "{}"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'lite-artifact-parser.ps1')

$AllowedSkills = @('codex')
$DeniedSkills = @('implement')
$AllowedTools = @('claudecode', 'codex')

function New-AdapterResult {
    param(
        [bool]$Ok,
        [string]$Status,
        [string[]]$ArtifactPaths = @(),
        [string]$NextStageHint = '',
        [string]$Handoff = '',
        [string[]]$Errors = @()
    )

    return [ordered]@{
        ok = $Ok
        status = $Status
        artifact_paths = @($ArtifactPaths)
        next_stage_hint = $NextStageHint
        handoff = $Handoff
        errors = @($Errors)
    }
}

function Write-Diagnostic {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        [Console]::Error.WriteLine($Message)
    }
}

function ConvertTo-PowerShellLiteral {
    param([object]$Value)

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return '$true'
        }

        return '$false'
    }

    if ($Value -is [string]) {
        return "'{0}'" -f ($Value -replace "'", "''")
    }

    if ($Value -is [System.Array]) {
        $items = @($Value | ForEach-Object { ConvertTo-PowerShellLiteral -Value $_ })
        return '@(' + ($items -join ', ') + ')'
    }

    return "'{0}'" -f ($Value.ToString() -replace "'", "''")
}

function Get-PayloadProperty {
    param(
        [object]$Payload,
        [string]$Name
    )

    if ($null -eq $Payload) {
        return $null
    }

    $matches = @($Payload.PSObject.Properties.Match($Name))
    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0].Value
}

function Resolve-CanonicalTaskPaths {
    param(
        [string]$WorkspaceRoot,
        [string]$TaskId
    )

    $taskRelativePath = Join-Path 'docs\tasks' $TaskId
    return [pscustomobject]@{
        TaskRelativePath = $taskRelativePath
        ArtifactDirectory = Resolve-LiteContainedPath -Root $WorkspaceRoot -RelativePath $taskRelativePath -Label 'task artifact directory'
        PlanPath = Resolve-LiteContainedPath -Root $WorkspaceRoot -RelativePath (Join-Path $taskRelativePath 'plan.md') -Label 'plan.md'
    }
}

function Assert-AdapterPlanIdentity {
    param(
        [string]$Content,
        [string]$TaskId,
        [string]$Stage
    )

    $fields = (Get-LiteFrontmatter -Content $Content).Fields
    if (-not $fields.Contains('task_id') -or $fields['task_id'] -cne $TaskId) {
        throw "TaskId does not match plan frontmatter: $TaskId"
    }
    if (-not $fields.Contains('stage') -or $fields['stage'] -cne $Stage) {
        throw "Stage does not match plan frontmatter: $Stage"
    }
    if ($Stage -ceq 'DONE') {
        if (-not $fields.Contains('tool') -or $fields['tool'] -cne 'none') {
            throw "DONE plan tool must be none."
        }
    } elseif (-not $fields.Contains('tool') -or $AllowedTools -cnotcontains $fields['tool']) {
        throw "Plan tool is not canonical."
    }
    return $fields
}

function Get-AdapterPlanGeneration {
    param([string]$Content)

    $trace = '- invocation: skill=[^ \t\r\n]+ mode=adapter tool=[^ \t\r\n]+ ok=(?:True|False) status=delegated'
    $withoutTrace = [regex]::Replace($Content, "(?m)^$trace(?:\r\n|\n)", '')
    $withoutTrace = [regex]::Replace($withoutTrace, "(?:\r\n|\n)$trace\z", '')
    return [regex]::Replace($withoutTrace, "\A$trace\z", '')
}

function Read-ToolProfileDescriptor {
    param(
        [string]$RepoRoot,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Tool profile name is empty.'
    }

    $normalizedName = $Name.Trim()
    if ($normalizedName -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw ("Unsupported tool profile name: {0}" -f $normalizedName)
    }

    $profilePath = Join-Path (Join-Path $RepoRoot 'agent-configs\profiles') ("{0}.yaml" -f $normalizedName)
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw ("Missing tool profile descriptor: {0}" -f $profilePath)
    }

    $fields = @{}
    $listFields = @{}
    $currentListKey = ''
    foreach ($line in (Get-Content -LiteralPath $profilePath -Encoding utf8)) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^([a-z_]+):\s*(.+?)\s*$') {
            $fields[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            $currentListKey = ''
            continue
        }

        if ($line -match '^([a-z_]+):\s*$') {
            $currentListKey = $Matches[1]
            if (-not $listFields.ContainsKey($currentListKey)) {
                $listFields[$currentListKey] = @()
            }
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($currentListKey) -and $line -match '^\s*-\s*(.+?)\s*$') {
            $listFields[$currentListKey] += $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        $currentListKey = ''
    }

    foreach ($required in @('name', 'backend')) {
        if (-not $fields.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($fields[$required])) {
            throw ("Tool profile {0} is missing required field: {1}" -f $normalizedName, $required)
        }
    }

    if ($fields['name'] -ne $normalizedName) {
        throw ("Tool profile file name {0} does not match descriptor name {1}" -f $normalizedName, $fields['name'])
    }

    return [pscustomobject]@{
        Name = $fields['name']
        Backend = $fields['backend']
        SkillDirs = @($listFields['skills_dirs'])
        Path = $profilePath
    }
}

function Get-DefaultUserSkillDir {
    param([string]$Backend)

    switch ($Backend) {
        'codex' {
            return '.codex\skills'
        }
        default {
            return '.claude\skills'
        }
    }
}

function Resolve-UserSkillDirCandidates {
    param(
        [string]$RepoRoot,
        [string]$Tool,
        [string]$ToolProfileId
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ToolProfileId)) {
        $profile = Read-ToolProfileDescriptor -RepoRoot $RepoRoot -Name $ToolProfileId
        if ($profile.Backend -cne $Tool) {
            throw "Tool profile backend '$($profile.Backend)' does not match Tool '$Tool'"
        }
        foreach ($skillDir in @($profile.SkillDirs)) {
            if ([string]::IsNullOrWhiteSpace($skillDir)) {
                continue
            }

            $normalizedSkillDir = $skillDir -replace '/', '\'
            if ([System.IO.Path]::IsPathRooted($normalizedSkillDir)) {
                $candidates += [System.IO.Path]::GetFullPath($normalizedSkillDir)
            } else {
                $candidates += (Join-Path $env:USERPROFILE $normalizedSkillDir)
            }
        }

        if ($candidates.Count -eq 0) {
            $candidates += (Join-Path $env:USERPROFILE (Get-DefaultUserSkillDir -Backend $profile.Backend))
        }
    }

    if ($candidates.Count -eq 0) {
        $candidates += (Join-Path $env:USERPROFILE (Get-DefaultUserSkillDir -Backend $Tool))
    }

    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Resolve-ActiveSkillDirs {
    param(
        [string]$WorkspaceRoot,
        [string]$Tool,
        [string]$ToolProfileId
    )

    $projectSkillsDir = Join-Path $WorkspaceRoot '.assistant\skills'
    if (Test-Path -LiteralPath $projectSkillsDir -PathType Container) {
        return [pscustomobject]@{
            Path = (Resolve-Path -LiteralPath $projectSkillsDir).Path
            Source = 'project-level'
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'USERPROFILE is not set and project-level .assistant\skills is missing.'
    }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $userCandidates = @(Resolve-UserSkillDirCandidates -RepoRoot $repoRoot -Tool $Tool -ToolProfileId $ToolProfileId)

    return [pscustomobject]@{
        Path = $userCandidates[0]
        Candidates = @($userCandidates)
        Source = 'user-level'
    }
}

function Invoke-ExternalPowerShellScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Missing adapter target script: $ScriptPath"
    }

    $supervisorPath = Join-Path $PSScriptRoot 'invoke-harness-skill-supervisor.ps1'
    if (-not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        throw "Missing adapter supervisor script: $supervisorPath"
    }

    $wrapperPath = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-harness-skill-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $commandParts = @("& { & " + (ConvertTo-PowerShellLiteral -Value $ScriptPath))
    foreach ($entry in $Parameters.GetEnumerator()) {
        $name = $entry.Key
        $value = $entry.Value
        if ($value -is [bool]) {
            if ($value) {
                $commandParts += " -$name"
            }
            continue
        }

        if ($value -is [System.Array] -and @($value).Count -eq 0) {
            continue
        }

        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if ($null -eq $value) {
            continue
        }

        $commandParts += (" -{0} {1}" -f $name, (ConvertTo-PowerShellLiteral -Value $value))
    }
    $commandParts += ' } *>&1'

    $wrapperContent = "Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction Stop`r`n"
    $wrapperContent += "`$InformationPreference = 'Continue'`r`n"
    $wrapperContent += "`$ErrorActionPreference = 'Stop'`r`n"
    $wrapperContent += ($commandParts -join '') + "`r`n"
    $wrapperContent += "exit `$LASTEXITCODE`r`n"

    try {
        [System.IO.File]::WriteAllText($wrapperPath, $wrapperContent, (New-Object System.Text.UTF8Encoding($false)))
        $powerShellPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
        $output = @(& $powerShellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $supervisorPath -TargetScriptPath $wrapperPath -OutputPath $Parameters.Output -TimeoutSeconds 1815 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = $output
        }
    } finally {
        Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-TargetTraceSection {
    param(
        [string]$Stage,
        [string]$PlanText
    )

    switch ($Stage) {
        'PLAN_REVIEW' {
            return '## Plan Review'
        }
        'CODE_REVIEW' {
            return '## Code Review'
        }
        'TEST' {
            if ($PlanText -match '(?m)^## Code Review\s*$') {
                return '## Code Review'
            }

            return ''
        }
        default {
            return ''
        }
    }
}

function Try-AppendInvocationTrace {
    param(
        [string]$WorkspaceRoot,
        [string]$TaskId,
        [string]$Stage,
        [string]$Skill,
        [string]$Tool,
        [object]$Result,
        [string]$ExpectedGeneration,
        [switch]$MutexHeld
    )

    $mutex = $null
    try {
        if (-not $MutexHeld) {
            $mutex = Enter-LitePlanMutex -TaskId $TaskId
        }

        $paths = Resolve-CanonicalTaskPaths -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
        if (-not (Test-Path -LiteralPath $paths.ArtifactDirectory -PathType Container) -or
            -not (Test-Path -LiteralPath $paths.PlanPath -PathType Leaf)) {
            return
        }

        $planText = Get-Content -LiteralPath $paths.PlanPath -Raw -Encoding utf8
        try {
            $null = Assert-AdapterPlanIdentity -Content $planText -TaskId $TaskId -Stage $Stage
        } catch {
            Write-Diagnostic 'invocation trace skipped: task or stage no longer matches plan frontmatter'
            return
        }
        if ((Get-AdapterPlanGeneration -Content $planText) -cne $ExpectedGeneration) {
            Write-Diagnostic 'invocation trace skipped: plan.md generation changed during adapter invocation'
            return
        }
        $sectionName = Get-TargetTraceSection -Stage $Stage -PlanText $planText
        if ([string]::IsNullOrWhiteSpace($sectionName)) {
            return
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        $lineEndings = [System.Collections.Generic.List[string]]::new()
        foreach ($lineMatch in [regex]::Matches($planText, '(?m)^(?<text>[^\r\n]*)(?<eol>\r\n|\n|$)')) {
            if ($lineMatch.Length -eq 0) {
                continue
            }
            $lines.Add($lineMatch.Groups['text'].Value)
            $lineEndings.Add($lineMatch.Groups['eol'].Value)
        }

        $sectionStart = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq $sectionName) {
                $sectionStart = $i
                break
            }
        }

        if ($sectionStart -lt 0) {
            Write-Diagnostic ("invocation trace skipped: no run block under {0}" -f $sectionName)
            return
        }

        $sectionEnd = $lines.Count
        for ($i = $sectionStart + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^##\s+') {
                $sectionEnd = $i
                break
            }
        }

        $runStart = -1
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match '^### Run \d+\b') {
                $runStart = $i
            }
        }

        if ($runStart -lt 0) {
            Write-Diagnostic ("invocation trace skipped: no run block under {0}" -f $sectionName)
            return
        }

        $insertAt = $sectionEnd
        for ($i = $runStart + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match '^### Run \d+\b') {
                $insertAt = $i
                break
            }
        }

        while ($insertAt -gt ($runStart + 1) -and $lines[$insertAt - 1] -eq '') {
            $insertAt--
        }

        $traceLine = "- invocation: skill=$Skill mode=adapter tool=$Tool ok=$($Result.ok) status=$($Result.status)"
        $traceEnding = if ($insertAt -lt $lineEndings.Count -and $lineEndings[$insertAt]) {
            $lineEndings[$insertAt]
        } elseif ($insertAt -gt 0 -and $lineEndings[$insertAt - 1]) {
            $lineEndings[$insertAt - 1]
        } else {
            [Environment]::NewLine
        }
        if ($insertAt -eq $lines.Count -and $lines.Count -gt 0 -and -not $lineEndings[$lines.Count - 1]) {
            $lineEndings[$lines.Count - 1] = $traceEnding
            $traceEnding = ''
        }
        $lines.Insert($insertAt, $traceLine)
        $lineEndings.Insert($insertAt, $traceEnding)
        $updatedPlan = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $null = $updatedPlan.Append($lines[$i]).Append($lineEndings[$i])
        }
        Write-LiteUtf8BomAtomic -Path $paths.PlanPath -Content $updatedPlan.ToString()
    } catch {
        Write-Diagnostic ("invocation trace skipped: {0}" -f $_.Exception.Message)
    } finally {
        if (-not $MutexHeld) {
            Exit-LitePlanMutex -Mutex $mutex
        }
    }
}

$artifactDirectory = ''
$planPath = ''
$backendOutputPath = ''
$taskCommitTempPath = ''
$taskCommitTempCreated = $false
$resolvedWorkspace = ''
$initialPlanGeneration = ''
$result = $null
$exitCode = 0

try {
    Assert-LiteTaskId -TaskId $TaskId
    if (-not (Test-CanonicalRuntimeStage -Stage $Stage)) {
        throw "Stage is not canonical: $Stage"
    }
    if ($Skill -cnotmatch '^[a-z][a-z0-9-]*$') {
        throw 'skill not in adapter whitelist'
    }
    if ($AllowedTools -cnotcontains $Tool) {
        throw "Unsupported Tool; expected one of: $($AllowedTools -join ', ')"
    }
    if (-not [string]::IsNullOrWhiteSpace($ToolProfileId)) {
        $requestedProfile = Read-ToolProfileDescriptor -RepoRoot (Split-Path -Parent $PSScriptRoot) -Name $ToolProfileId
        if ($requestedProfile.Backend -cne $Tool) {
            throw "Tool profile backend '$($requestedProfile.Backend)' does not match Tool '$Tool'"
        }
    }
    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $initialPaths = Resolve-CanonicalTaskPaths -WorkspaceRoot $resolvedWorkspace -TaskId $TaskId
    $planPath = $initialPaths.PlanPath
    $initialMutex = Enter-LitePlanMutex -TaskId $TaskId
    try {
        $initialPaths = Resolve-CanonicalTaskPaths -WorkspaceRoot $resolvedWorkspace -TaskId $TaskId
        $artifactDirectory = $initialPaths.ArtifactDirectory
        $planPath = $initialPaths.PlanPath
        if (-not (Test-Path -LiteralPath $artifactDirectory -PathType Container)) {
            throw "Task artifact directory does not exist: $artifactDirectory"
        }
        if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
            throw "Task plan does not exist: $planPath"
        }
        $initialPlanText = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
        $planFields = Assert-AdapterPlanIdentity -Content $initialPlanText -TaskId $TaskId -Stage $Stage
        $initialPlanGeneration = Get-AdapterPlanGeneration -Content $initialPlanText
        $hasReservedTaskSkillsDir = $planFields.Contains('skills_dir') -and -not [string]::IsNullOrWhiteSpace($planFields['skills_dir'])
    } finally {
        Exit-LitePlanMutex -Mutex $initialMutex
    }
    if ($hasReservedTaskSkillsDir) {
        Write-Diagnostic 'task-level skills_dir is reserved in Phase 3 and ignored.'
    }

    $normalizedSkill = $Skill.Trim().ToLowerInvariant()
    $payload = if ([string]::IsNullOrWhiteSpace($PayloadJson)) {
        [pscustomobject]@{}
    } else {
        $PayloadJson | ConvertFrom-Json
    }
    if ($null -eq $payload -or $payload.GetType().FullName -cne 'System.Management.Automation.PSCustomObject') {
        throw 'PayloadJson must encode a JSON object.'
    }
    foreach ($propertyName in @('task', 'session', 'model', 'reasoning')) {
        $propertyValue = Get-PayloadProperty -Payload $payload -Name $propertyName
        if ($null -ne $propertyValue -and $propertyValue -isnot [string]) {
            throw "PayloadJson.$propertyName must be a string."
        }
    }
    $payloadFileValue = Get-PayloadProperty -Payload $payload -Name 'file'
    if ($null -ne $payloadFileValue -and
        $payloadFileValue -isnot [string] -and
        ($payloadFileValue -isnot [System.Array] -or @($payloadFileValue | Where-Object { $_ -isnot [string] }).Count -gt 0)) {
        throw 'PayloadJson.file must be a string or an array of strings.'
    }
    if ($normalizedSkill -ceq 'codex' -and $Mode -ceq 'readonly' -and [string]::IsNullOrWhiteSpace([string](Get-PayloadProperty -Payload $payload -Name 'task'))) {
        throw 'PayloadJson.task is required for codex delegation.'
    }

    if ($normalizedSkill -in $DeniedSkills) {
        $message = 'implement skill must be run by human; adapter refuses side-effect skills (S11 / R11)'
        Write-Diagnostic $message
        $result = New-AdapterResult -Ok $false -Status 'rejected' -Errors @($message)
        $exitCode = 1
    } elseif ($normalizedSkill -notin $AllowedSkills) {
        $message = 'skill not in adapter whitelist'
        Write-Diagnostic ("{0}: {1}" -f $message, $normalizedSkill)
        $result = New-AdapterResult -Ok $false -Status 'rejected' -Errors @($message)
        $exitCode = 1
    } else {
        switch ($normalizedSkill) {
            'codex' {
                if ($Mode -ne 'readonly') {
                    $message = 'codex adapter only supports readonly mode'
                    Write-Diagnostic $message
                    $result = New-AdapterResult -Ok $false -Status 'rejected' -Errors @($message)
                    $exitCode = 1
                    break
                }

                $skillRoot = Resolve-ActiveSkillDirs -WorkspaceRoot $resolvedWorkspace -Tool $Tool -ToolProfileId $ToolProfileId
                $scriptPath = Join-Path $skillRoot.Path 'codex\scripts\ask_codex.ps1'
                $backendOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-harness-skill-output-' + [guid]::NewGuid().ToString('N') + '.tmp')
                $payloadFiles = @(Get-PayloadProperty -Payload $payload -Name 'file')
                $parameters = [ordered]@{
                    Task = [string](Get-PayloadProperty -Payload $payload -Name 'task')
                    Workspace = $resolvedWorkspace
                    File = @($payloadFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                    Session = [string](Get-PayloadProperty -Payload $payload -Name 'session')
                    Model = [string](Get-PayloadProperty -Payload $payload -Name 'model')
                    Reasoning = if ([string]::IsNullOrWhiteSpace([string](Get-PayloadProperty -Payload $payload -Name 'reasoning'))) { 'medium' } else { [string](Get-PayloadProperty -Payload $payload -Name 'reasoning') }
                    TimeoutSeconds = 1800
                    ReadOnly = $true
                    Output = $backendOutputPath
                }

                $invocation = Invoke-ExternalPowerShellScript -ScriptPath $scriptPath -Parameters $parameters
                $sessionId = ''
                $diagnostics = @()
                $backendOutputFrames = [System.Collections.Generic.List[string]]::new()
                $backendOutputFramePrefix = '__DEV_HARNESS_BACKEND_OUTPUT_BASE64__='
                foreach ($line in $invocation.Output) {
                    if ($line.StartsWith($backendOutputFramePrefix, [System.StringComparison]::Ordinal)) {
                        $backendOutputFrames.Add($line.Substring($backendOutputFramePrefix.Length))
                        continue
                    }
                    if ($line -match '^session_id=(.+)$') {
                        $sessionId = $Matches[1]
                        continue
                    }
                    if ($line -match '^output_path=(.+)$') {
                        continue
                    }
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $diagnostics += $line
                    }
                }
                if ($invocation.ExitCode -ne 0) {
                    $diagnostics += "codex adapter exited with code $($invocation.ExitCode)"
                }

                foreach ($line in $diagnostics) {
                    Write-Diagnostic $line
                }

                if ($invocation.ExitCode -eq 0) {
                    if ($backendOutputFrames.Count -ne 1) {
                        throw "codex adapter expected exactly one backend output frame, got $($backendOutputFrames.Count)"
                    }
                    try {
                        $backendBytes = [System.Convert]::FromBase64String($backendOutputFrames[0])
                    } catch [System.FormatException] {
                        throw 'codex adapter backend output frame is not valid Base64'
                    }

                    $handoff = if ([string]::IsNullOrWhiteSpace($sessionId)) { '' } else { "session_id=$sessionId" }
                    $commitMutex = Enter-LitePlanMutex -TaskId $TaskId
                    try {
                        $commitPaths = Resolve-CanonicalTaskPaths -WorkspaceRoot $resolvedWorkspace -TaskId $TaskId
                        if (-not (Test-Path -LiteralPath $commitPaths.ArtifactDirectory -PathType Container) -or
                            -not (Test-Path -LiteralPath $commitPaths.PlanPath -PathType Leaf)) {
                            throw 'Canonical task artifact or plan disappeared before artifact commit.'
                        }
                        $commitPlanText = Get-Content -LiteralPath $commitPaths.PlanPath -Raw -Encoding utf8
                        $null = Assert-AdapterPlanIdentity -Content $commitPlanText -TaskId $TaskId -Stage $Stage
                        if ((Get-AdapterPlanGeneration -Content $commitPlanText) -cne $initialPlanGeneration) {
                            throw 'plan.md generation changed while adapter backend was running; stale result was discarded.'
                        }

                        $finalLeaf = 'codex-{0}-{1}.md' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff'), [guid]::NewGuid().ToString('N')
                        $finalPath = Resolve-LiteContainedPath -Root $resolvedWorkspace -RelativePath (Join-Path $commitPaths.TaskRelativePath $finalLeaf) -Label 'codex artifact'
                        $taskCommitTempLeaf = '.{0}.{1}.tmp' -f $finalLeaf, [guid]::NewGuid().ToString('N')
                        $taskCommitTempPath = Resolve-LiteContainedPath -Root $resolvedWorkspace -RelativePath (Join-Path $commitPaths.TaskRelativePath $taskCommitTempLeaf) -Label 'codex artifact temp'
                        $destination = New-Object System.IO.FileStream($taskCommitTempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                        $taskCommitTempCreated = $true
                        try {
                            $destination.Write($backendBytes, 0, $backendBytes.Length)
                            $destination.Flush($true)
                        } finally {
                            $destination.Dispose()
                        }

                        $publishPaths = Resolve-CanonicalTaskPaths -WorkspaceRoot $resolvedWorkspace -TaskId $TaskId
                        $publishPlanText = Get-Content -LiteralPath $publishPaths.PlanPath -Raw -Encoding utf8
                        $null = Assert-AdapterPlanIdentity -Content $publishPlanText -TaskId $TaskId -Stage $Stage
                        if ((Get-AdapterPlanGeneration -Content $publishPlanText) -cne $initialPlanGeneration) {
                            throw 'plan.md generation changed while adapter backend was running; stale result was discarded.'
                        }
                        $finalPath = Resolve-LiteContainedPath -Root $resolvedWorkspace -RelativePath (Join-Path $publishPaths.TaskRelativePath $finalLeaf) -Label 'codex artifact'
                        $taskCommitTempPath = Resolve-LiteContainedPath -Root $resolvedWorkspace -RelativePath (Join-Path $publishPaths.TaskRelativePath $taskCommitTempLeaf) -Label 'codex artifact temp'
                        [System.IO.File]::Move($taskCommitTempPath, $finalPath)
                        $taskCommitTempCreated = $false
                        $taskCommitTempPath = ''

                        $result = New-AdapterResult -Ok $true -Status 'delegated' -ArtifactPaths @($finalPath) -Handoff $handoff
                        Try-AppendInvocationTrace -WorkspaceRoot $resolvedWorkspace -TaskId $TaskId -Stage $Stage -Skill $Skill -Tool $Tool -Result $result -ExpectedGeneration $initialPlanGeneration -MutexHeld
                    } finally {
                        Exit-LitePlanMutex -Mutex $commitMutex
                    }
                } else {
                    $result = New-AdapterResult -Ok $false -Status 'error' -Errors $diagnostics
                    $exitCode = 1
                }
            }
        }
    }
} catch {
    Write-Diagnostic $_.Exception.Message
    $result = New-AdapterResult -Ok $false -Status 'error' -Errors @($_.Exception.Message)
    $exitCode = 1
} finally {
    $tempPaths = @($backendOutputPath)
    if ($taskCommitTempCreated) {
        $tempPaths += $taskCommitTempPath
    }
    foreach ($tempPath in $tempPaths) {
        if ([string]::IsNullOrWhiteSpace($tempPath)) {
            continue
        }
        try {
            [System.IO.File]::Delete($tempPath)
        } catch {
            Write-Diagnostic ("failed to clean adapter temp: {0}" -f $_.Exception.Message)
        }
    }
}

if ($null -eq $result) {
    $result = New-AdapterResult -Ok $false -Status 'error' -Errors @('adapter produced no result')
    $exitCode = 1
}

[Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 8))
exit $exitCode
