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

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [ValidateSet('readonly', 'writable')]
    [string]$Mode = 'readonly',

    [string]$PayloadJson = "{}"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AllowedSkills = @('review', 'test', 'gemini-designer-main', 'codex')
$DeniedSkills = @('implement')

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

function Write-JsonNoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
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

function Get-Frontmatter {
    param([string]$Text)

    $map = @{}
    if ($Text -notmatch "(?s)^---\r?\n(.*?)\r?\n---\r?\n") {
        return $map
    }

    foreach ($line in ($Matches[1] -split "\r?\n")) {
        if ($line -match "^\s*([^:]+):\s*(.+?)\s*$") {
            $map[$Matches[1]] = $Matches[2]
        }
    }

    return $map
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

function Resolve-ArtifactDirectory {
    param([string]$ArtifactRoot)

    $fullPath = [System.IO.Path]::GetFullPath($ArtifactRoot)
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        if ((Split-Path -Leaf $fullPath) -ieq 'plan.md') {
            return (Split-Path -Parent $fullPath)
        }

        throw "ArtifactRoot must be a task directory or plan.md path, got file: $ArtifactRoot"
    }

    return $fullPath
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
        'gemini' {
            return '.gemini\skills'
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
        try {
            $profile = Read-ToolProfileDescriptor -RepoRoot $RepoRoot -Name $ToolProfileId
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
        } catch {
            Write-Diagnostic ("tool profile {0} skills_dirs lookup failed; falling back to backend {1}: {2}" -f $ToolProfileId, $Tool, $_.Exception.Message)
        }
    }

    if ($candidates.Count -eq 0) {
        $candidates += (Join-Path $env:USERPROFILE (Get-DefaultUserSkillDir -Backend $Tool))
    }

    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Resolve-ActiveSkillDirs {
    param(
        [string]$TaskId,
        [string]$WorkspaceRoot,
        [string]$ArtifactRoot,
        [string]$Tool,
        [string]$ToolProfileId
    )

    $artifactDirectory = Resolve-ArtifactDirectory -ArtifactRoot $ArtifactRoot
    $planPath = Join-Path $artifactDirectory 'plan.md'
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $frontmatter = Get-Frontmatter -Text (Get-Content -LiteralPath $planPath -Raw -Encoding utf8)
        if ($frontmatter.ContainsKey('skills_dir') -and -not [string]::IsNullOrWhiteSpace($frontmatter['skills_dir'])) {
            Write-Diagnostic 'task-level skills_dir is reserved in Phase 3 and ignored.'
        }
    }

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

function Resolve-AdapterScriptPath {
    param(
        [string]$SkillRoot,
        [string]$Skill
    )

    switch ($Skill) {
        'codex' {
            return Join-Path $SkillRoot 'codex\scripts\ask_codex.ps1'
        }
        'gemini-designer-main' {
            return Join-Path $SkillRoot 'gemini-designer-main\scripts\invoke-gemini.ps1'
        }
        default {
            return ''
        }
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

    $wrapperContent = "`$InformationPreference = 'Continue'`r`n"
    $wrapperContent += "`$ErrorActionPreference = 'Stop'`r`n"
    $wrapperContent += ($commandParts -join '') + "`r`n"
    $wrapperContent += "exit `$LASTEXITCODE`r`n"

    try {
        Write-JsonNoBom -Path $wrapperPath -Content $wrapperContent
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapperPath 2>&1 | ForEach-Object { [string]$_ })
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

function Get-MutexName {
    param([string]$PlanPath)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlanPath.ToLowerInvariant())
    $hashBytes = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
    $hash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    return "Global\invoke-harness-skill.plan-md.$hash"
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Try-AppendInvocationTrace {
    param(
        [string]$ArtifactRoot,
        [string]$Stage,
        [string]$Skill,
        [string]$Tool,
        [object]$Result
    )

    $artifactDirectory = Resolve-ArtifactDirectory -ArtifactRoot $ArtifactRoot
    $planPath = Join-Path $artifactDirectory 'plan.md'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        return
    }

    $planText = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
    $sectionName = Get-TargetTraceSection -Stage $Stage -PlanText $planText
    if ([string]::IsNullOrWhiteSpace($sectionName)) {
        return
    }

    $mutex = $null
    $hasHandle = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, (Get-MutexName -PlanPath $planPath))
        $hasHandle = $mutex.WaitOne(5000)
        if (-not $hasHandle) {
            Write-Diagnostic ("invocation trace skipped: mutex timeout for {0}" -f $sectionName)
            return
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-Content -LiteralPath $planPath -Encoding utf8)) {
            $lines.Add($line)
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

        $traceLine = "- invocation: skill=$Skill mode=adapter tool=$Tool ok=$($Result.ok)"
        $lines.Insert($insertAt, $traceLine)
        Write-Utf8Bom -Path $planPath -Content ($lines -join "`r`n")
    } catch {
        Write-Diagnostic ("invocation trace skipped: {0}" -f $_.Exception.Message)
    } finally {
        if ($hasHandle -and $null -ne $mutex) {
            $mutex.ReleaseMutex() | Out-Null
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

$artifactDirectory = ''
$result = $null
$exitCode = 0

try {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    $artifactDirectory = Resolve-ArtifactDirectory -ArtifactRoot $ArtifactRoot
    if (-not (Test-Path -LiteralPath $artifactDirectory -PathType Container)) {
        throw "ArtifactRoot directory does not exist: $artifactDirectory"
    }

    $normalizedSkill = $Skill.Trim().ToLowerInvariant()
    $payload = if ([string]::IsNullOrWhiteSpace($PayloadJson)) {
        [pscustomobject]@{}
    } else {
        $PayloadJson | ConvertFrom-Json
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
            'review' {
                $message = 'review/test adapter is stub; fall back to Markdown-skill flow'
                Write-Diagnostic $message
                $result = New-AdapterResult -Ok $true -Status 'markdown-fallback'
            }
            'test' {
                $message = 'review/test adapter is stub; fall back to Markdown-skill flow'
                Write-Diagnostic $message
                $result = New-AdapterResult -Ok $true -Status 'markdown-fallback'
            }
            'codex' {
                if ($Mode -ne 'readonly') {
                    $message = 'codex adapter only supports readonly mode'
                    Write-Diagnostic $message
                    $result = New-AdapterResult -Ok $false -Status 'rejected' -Errors @($message)
                    $exitCode = 1
                    break
                }

                $skillRoot = Resolve-ActiveSkillDirs -TaskId $TaskId -WorkspaceRoot $resolvedWorkspace -ArtifactRoot $artifactDirectory -Tool $Tool -ToolProfileId $ToolProfileId
                $scriptPath = Resolve-AdapterScriptPath -SkillRoot $skillRoot.Path -Skill $normalizedSkill
                $outputPath = Join-Path $artifactDirectory ('codex-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '.md')
                $payloadFiles = @(Get-PayloadProperty -Payload $payload -Name 'file')
                $parameters = [ordered]@{
                    Task = [string](Get-PayloadProperty -Payload $payload -Name 'task')
                    Workspace = $resolvedWorkspace
                    File = @($payloadFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                    Session = [string](Get-PayloadProperty -Payload $payload -Name 'session')
                    Model = [string](Get-PayloadProperty -Payload $payload -Name 'model')
                    Reasoning = if ([string]::IsNullOrWhiteSpace([string](Get-PayloadProperty -Payload $payload -Name 'reasoning'))) { 'medium' } else { [string](Get-PayloadProperty -Payload $payload -Name 'reasoning') }
                    ReadOnly = $true
                    Output = $outputPath
                }

                $invocation = Invoke-ExternalPowerShellScript -ScriptPath $scriptPath -Parameters $parameters
                $artifactPaths = @()
                $sessionId = ''
                $diagnostics = @()
                foreach ($line in $invocation.Output) {
                    if ($line -match '^session_id=(.+)$') {
                        $sessionId = $Matches[1]
                        continue
                    }
                    if ($line -match '^output_path=(.+)$') {
                        $artifactPaths += $Matches[1]
                        continue
                    }
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $diagnostics += $line
                    }
                }

                foreach ($line in $diagnostics) {
                    Write-Diagnostic $line
                }

                if ($artifactPaths.Count -eq 0 -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
                    $artifactPaths += $outputPath
                }

                if ($invocation.ExitCode -eq 0) {
                    $handoff = if ([string]::IsNullOrWhiteSpace($sessionId)) { '' } else { "session_id=$sessionId" }
                    $result = New-AdapterResult -Ok $true -Status 'delegated' -ArtifactPaths $artifactPaths -Handoff $handoff
                } else {
                    $errors = if ($diagnostics.Count -gt 0) { $diagnostics } else { @("codex adapter exited with code $($invocation.ExitCode)") }
                    $result = New-AdapterResult -Ok $false -Status 'error' -ArtifactPaths $artifactPaths -Errors $errors
                    $exitCode = 1
                }
            }
            'gemini-designer-main' {
                $skillRoot = Resolve-ActiveSkillDirs -TaskId $TaskId -WorkspaceRoot $resolvedWorkspace -ArtifactRoot $artifactDirectory -Tool $Tool -ToolProfileId $ToolProfileId
                $scriptPath = Resolve-AdapterScriptPath -SkillRoot $skillRoot.Path -Skill $normalizedSkill
                $parameters = [ordered]@{
                    Workspace = $resolvedWorkspace
                    Prompt = [string](Get-PayloadProperty -Payload $payload -Name 'prompt')
                    OutputFormat = 'json'
                    ApprovalMode = 'plan'
                    Model = [string](Get-PayloadProperty -Payload $payload -Name 'model')
                }

                $invocation = Invoke-ExternalPowerShellScript -ScriptPath $scriptPath -Parameters $parameters
                $joinedOutput = ($invocation.Output -join "`n").Trim()
                $parsed = $null
                if (-not [string]::IsNullOrWhiteSpace($joinedOutput)) {
                    $parsed = $joinedOutput | ConvertFrom-Json
                }

                if ($invocation.ExitCode -eq 0 -and $null -ne $parsed -and $parsed.ok) {
                    $handoff = if ([string]::IsNullOrWhiteSpace([string]$parsed.stdout)) { '' } else { [string]$parsed.stdout }
                    $result = New-AdapterResult -Ok $true -Status 'delegated' -Handoff $handoff
                } else {
                    $message = if ($null -ne $parsed -and $parsed.stdout) {
                        [string]$parsed.stdout
                    } elseif (-not [string]::IsNullOrWhiteSpace($joinedOutput)) {
                        $joinedOutput
                    } else {
                        "gemini adapter exited with code $($invocation.ExitCode)"
                    }
                    Write-Diagnostic $message
                    $result = New-AdapterResult -Ok $false -Status 'error' -Errors @($message)
                    $exitCode = 1
                }
            }
        }
    }
} catch {
    Write-Diagnostic $_.Exception.Message
    $result = New-AdapterResult -Ok $false -Status 'error' -Errors @($_.Exception.Message)
    $exitCode = 1
}

if ($null -eq $result) {
    $result = New-AdapterResult -Ok $false -Status 'error' -Errors @('adapter produced no result')
    $exitCode = 1
}

if (-not [string]::IsNullOrWhiteSpace($artifactDirectory)) {
    Try-AppendInvocationTrace -ArtifactRoot $artifactDirectory -Stage $Stage -Skill $Skill -Tool $Tool -Result $result
}

[Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 8))
exit $exitCode
