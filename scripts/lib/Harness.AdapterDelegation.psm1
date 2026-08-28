Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop

$script:PreparedDelegations = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$script:CanonicalStages = @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')
$script:AllowedTools = @('claudecode','codex')

function Assert-HarnessDelegationExactKeys {
    param([Collections.IDictionary]$Value,[string[]]$Expected,[string]$Label)

    if ($null -eq $Value) { throw "$Label must be an object" }
    $actual = @($Value.Keys | ForEach-Object { [string]$_ })
    if (@($Expected | Where-Object { $actual -cnotcontains $_ }).Count -or
        @($actual | Where-Object { $_ -cnotin $Expected }).Count) {
        throw "$Label has missing or unknown fields"
    }
}

function Assert-HarnessDelegationEnvelope {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Envelope,
        [Parameter(Mandatory)][ValidateSet('request','response')][string]$MessageType,
        [Parameter(Mandatory)][ValidateSet('prepare_delegation','commit_delegation')][string]$Operation
    )

    Assert-HarnessDelegationExactKeys -Value $Envelope -Expected @('schema_version','message_type','body') -Label 'adapter-kernel-api/v1 envelope'
    if ($Envelope.schema_version -isnot [string] -or [string]$Envelope.schema_version -cne 'adapter-kernel-api/v1' -or
        $Envelope.message_type -isnot [string] -or [string]$Envelope.message_type -cne $MessageType -or
        $Envelope.body -isnot [Collections.IDictionary]) {
        throw "adapter-kernel-api/v1 $Operation $MessageType is invalid"
    }
    $expected = switch ("$MessageType/$Operation") {
        'request/prepare_delegation' { @('operation','repo_root','workspace_root','task_id','stage','skill','tool','tool_profile_id','mode','payload_json') }
        'request/commit_delegation' { @('operation','delegation_id','succeeded','artifact_base64','session_id','diagnostics') }
        'response/prepare_delegation' { @('operation','delegation_id','backend_script','backend_output_path','backend_task','backend_workspace','backend_files','backend_session','backend_model','backend_reasoning','backend_timeout_seconds','backend_read_only','warnings') }
        'response/commit_delegation' { @('operation','result','warnings') }
    }
    Assert-HarnessDelegationExactKeys -Value $Envelope.body -Expected $expected -Label "adapter-kernel-api/v1 $Operation $MessageType"
    if ($Envelope.body.operation -isnot [string] -or [string]$Envelope.body.operation -cne $Operation) {
        throw "adapter-kernel-api/v1 $Operation $MessageType is invalid"
    }
    return $Envelope.body
}

function New-HarnessAdapterResult {
    param(
        [bool]$Ok,
        [ValidateSet('delegated','error','rejected')][string]$Status,
        [string[]]$ArtifactPaths = @(),
        [string]$Handoff = '',
        [string[]]$Errors = @()
    )

    return [ordered]@{
        ok = $Ok
        status = $Status
        artifact_paths = @($ArtifactPaths)
        next_stage_hint = ''
        handoff = $Handoff
        errors = @($Errors)
    }
}

function Throw-HarnessAdapterRejection {
    param([Parameter(Mandatory)][string]$Message)

    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['adapter_status'] = 'rejected'
    throw $exception
}

function Enter-HarnessAdapterPlanMutex {
    param([Parameter(Mandatory)][string]$TaskId,[int]$TimeoutMilliseconds = 5000)

    $mutex = [Threading.Mutex]::new($false,"Global\dev-harness.plan-md.$TaskId")
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting for task plan lock: $TaskId" }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-HarnessAdapterPlanMutex {
    param([Threading.Mutex]$Mutex)

    if ($null -eq $Mutex) { return }
    try { [void]$Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Resolve-HarnessDelegationWorkspace {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $fullPath = [IO.Path]::GetFullPath($WorkspaceRoot)
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'WorkspaceRoot contains a reparse point'
    }
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fullPath -ErrorAction Stop).ProviderPath)
    $volumeRoot = [IO.Path]::GetPathRoot($resolved)
    if (-not $resolved.Equals($volumeRoot,[StringComparison]::OrdinalIgnoreCase)) {
        $resolved = $resolved.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    }
    return $resolved
}

function Resolve-HarnessDelegationContainedPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [string]$Label='path',
        [ValidateSet('Any','File','Directory')][string]$MustExist='Any',
        [switch]$AllowMissing
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $rootPath $Path)) }
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.Equals($rootPath,[StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its root"
    }
    $cursor = $candidate
    while (-not (Test-Path -LiteralPath $cursor)) {
        $cursor = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($cursor)) { throw "$Label has no existing parent" }
    }
    while ($cursor.Length -ge $rootPath.Length -and $cursor.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label contains a reparse point" }
        if ($cursor.Equals($rootPath,[StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $exists = Test-Path -LiteralPath $candidate
    if (-not $exists -and -not $AllowMissing) { throw "$Label does not exist" }
    if ($exists -and $MustExist -ceq 'File' -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "$Label is not a file" }
    if ($exists -and $MustExist -ceq 'Directory' -and -not (Test-Path -LiteralPath $candidate -PathType Container)) { throw "$Label is not a directory" }
    return $candidate
}

function Resolve-HarnessDelegationTaskPaths {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId)

    $taskRelative = "docs/tasks/$TaskId"
    return [pscustomobject]@{
        TaskRelativePath = $taskRelative
        ArtifactDirectory = Resolve-HarnessDelegationContainedPath -Root $WorkspaceRoot -Path $taskRelative -Label 'task artifact directory' -MustExist Directory
        PlanPath = Resolve-HarnessDelegationContainedPath -Root $WorkspaceRoot -Path "$taskRelative/plan.md" -Label 'plan.md' -MustExist File
    }
}

function Get-HarnessAdapterFrontmatter {
    param([Parameter(Mandatory)][string]$Content)

    $match = [regex]::Match($Content,'\A---\r?\n(.*?)\r?\n---\r?\n',[Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'missing frontmatter block' }
    $fields = [ordered]@{}
    foreach ($line in ($match.Groups[1].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([a-z_]+):\s*(.+)$') { throw "invalid frontmatter line: $line" }
        if ($fields.Contains($Matches[1])) { throw "duplicate frontmatter field: $($Matches[1])" }
        $fields[$Matches[1]] = $Matches[2].Trim()
    }
    return $fields
}

function Assert-HarnessAdapterPlanIdentity {
    param([string]$Content,[string]$TaskId,[string]$Stage)

    $fields = Get-HarnessAdapterFrontmatter -Content $Content
    if (-not $fields.Contains('task_id') -or $fields.task_id -cne $TaskId) {
        throw "TaskId does not match plan frontmatter: $TaskId"
    }
    if (-not $fields.Contains('stage') -or $fields.stage -cne $Stage) {
        throw "Stage does not match plan frontmatter: $Stage"
    }
    if ($Stage -ceq 'DONE') {
        if (-not $fields.Contains('tool') -or $fields.tool -cne 'none') { throw 'DONE plan tool must be none.' }
    } elseif (-not $fields.Contains('tool') -or $script:AllowedTools -cnotcontains $fields.tool) {
        throw 'Plan tool is not canonical.'
    }
    return $fields
}

function Get-HarnessAdapterPlanGeneration {
    param([Parameter(Mandatory)][string]$Content)

    $trace = '- invocation: skill=[^ \t\r\n]+ mode=adapter tool=[^ \t\r\n]+ ok=(?:True|False) status=delegated'
    $withoutTrace = [regex]::Replace($Content,"(?m)^$trace(?:\r\n|\n)",'')
    $withoutTrace = [regex]::Replace($withoutTrace,"(?:\r\n|\n)$trace\z",'')
    $withoutTrace = [regex]::Replace($withoutTrace,"\A$trace\z",'')
    return Get-HarnessUtf8TextSha256 -Text $withoutTrace
}

function Read-HarnessToolProfile {
    param([string]$RepoRoot,[string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Tool profile name is empty.' }
    $normalized = $Name.Trim()
    if ($normalized -notmatch '^[a-z0-9][a-z0-9._-]*$') { throw "Unsupported tool profile name: $normalized" }
    $path = Resolve-HarnessDelegationContainedPath -Root $RepoRoot -Path "agent-configs/profiles/$normalized.yaml" -Label 'tool profile descriptor' -AllowMissing
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing tool profile descriptor: $path" }
    $fields = @{}
    $lists = @{}
    $currentList = ''
    foreach ($line in (Get-Content -LiteralPath $path -Encoding utf8)) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^([a-z_]+):\s*(.+?)\s*$') {
            $fields[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            $currentList = ''
            continue
        }
        if ($line -match '^([a-z_]+):\s*$') {
            $currentList = $Matches[1]
            if (-not $lists.ContainsKey($currentList)) { $lists[$currentList] = @() }
            continue
        }
        if ($currentList -and $line -match '^\s*-\s*(.+?)\s*$') {
            $lists[$currentList] += $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }
        $currentList = ''
    }
    foreach ($required in @('name','backend')) {
        if (-not $fields.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($fields[$required])) {
            throw "Tool profile $normalized is missing required field: $required"
        }
    }
    if ($fields.name -cne $normalized) { throw "Tool profile file name $normalized does not match descriptor name $($fields.name)" }
    return [pscustomobject]@{ Name=$fields.name;Backend=$fields.backend;SkillDirs=@($lists.skills_dirs) }
}

function Resolve-HarnessAdapterSkillRoot {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Tool,[string]$ToolProfileId)

    $project = Resolve-HarnessDelegationContainedPath -Root $WorkspaceRoot -Path '.assistant/skills' -Label 'project skill root' -AllowMissing
    if (Test-Path -LiteralPath $project -PathType Container) { return $project }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'USERPROFILE is not set and project-level .assistant\skills is missing.'
    }
    $candidates = [Collections.Generic.List[string]]::new()
    if ($ToolProfileId) {
        $profile = Read-HarnessToolProfile -RepoRoot $RepoRoot -Name $ToolProfileId
        if ($profile.Backend -cne $Tool) { throw "Tool profile backend '$($profile.Backend)' does not match Tool '$Tool'" }
        foreach ($entry in @($profile.SkillDirs)) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $path = $entry -replace '/','\'
            $candidates.Add($(if ([IO.Path]::IsPathRooted($path)) { [IO.Path]::GetFullPath($path) } else { Join-Path $env:USERPROFILE $path }))
        }
    }
    if ($candidates.Count -eq 0) {
        $relative = if ($Tool -ceq 'codex') { '.codex\skills' } else { '.claude\skills' }
        $candidates.Add((Join-Path $env:USERPROFILE $relative))
    }
    return $candidates[0]
}

function ConvertFrom-HarnessAdapterPayload {
    param([Parameter(Mandatory)][string]$PayloadJson)

    try { $document = $PayloadJson | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "PayloadJson must encode a JSON object: $($_.Exception.Message)"
    }
    if ($null -eq $document -or $document.GetType().FullName -cne 'System.Management.Automation.PSCustomObject') {
        throw 'PayloadJson must encode a JSON object.'
    }
    $payload = [ordered]@{}
    foreach ($property in $document.PSObject.Properties) { $payload[$property.Name] = $property.Value }
    $allowed = @('task','file','session','model','reasoning')
    if (@($payload.Keys | Where-Object { [string]$_ -cnotin $allowed }).Count) {
        throw 'PayloadJson contains an unknown field.'
    }
    foreach ($name in @('task','session','model','reasoning')) {
        if ($payload.Contains($name) -and $payload[$name] -isnot [string]) { throw "PayloadJson.$name must be a string." }
    }
    if ($payload.Contains('file') -and $payload.file -isnot [string] -and
        ($payload.file -isnot [Collections.IList] -or $payload.file -is [string] -or
        @($payload.file | Where-Object { $_ -isnot [string] }).Count)) {
        throw 'PayloadJson.file must be a string or an array of strings.'
    }
    return $payload
}

function Write-HarnessAdapterPlanAtomic {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)

    $directory = [IO.Path]::GetDirectoryName($Path)
    $temp = Join-Path $directory ('.{0}.{1}.{2}.tmp' -f [IO.Path]::GetFileName($Path),$PID,[guid]::NewGuid().ToString('N'))
    $backup = "$temp.bak"
    try {
        $encoding = [Text.UTF8Encoding]::new($true)
        $preamble = $encoding.GetPreamble()
        $bytes = $encoding.GetBytes($Content)
        $stream = [IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($preamble,0,$preamble.Length)
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        [IO.File]::Replace($temp,$Path,$backup,$true)
    } finally {
        foreach ($candidate in @($temp,$backup)) { if ([IO.File]::Exists($candidate)) { [IO.File]::Delete($candidate) } }
    }
}

function Add-HarnessAdapterInvocationTrace {
    param([string]$PlanText,[string]$Stage,[string]$Skill,[string]$Tool)

    $section = switch ($Stage) {
        'PLAN_REVIEW' { '## Plan Review' }
        'CODE_REVIEW' { '## Code Review' }
        'TEST' { if ($PlanText -match '(?m)^## Code Review\s*$') { '## Code Review' } else { '' } }
        default { '' }
    }
    if (-not $section) { return $null }
    $heading = [regex]::Match($PlanText,"(?m)^$([regex]::Escape($section))\s*(?:\r\n|\n)")
    if (-not $heading.Success) { return "invocation trace skipped: no run block under $section" }
    $next = [regex]::new('(?m)^##\s+').Match($PlanText,$heading.Index + $heading.Length)
    $sectionEnd = if ($next.Success) { $next.Index } else { $PlanText.Length }
    $body = $PlanText.Substring($heading.Index + $heading.Length,$sectionEnd - $heading.Index - $heading.Length)
    if ($body -notmatch '(?m)^### Run \d+\b') { return "invocation trace skipped: no run block under $section" }
    $ending = if ($PlanText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $prefix = $PlanText.Substring(0,$sectionEnd)
    if (-not $prefix.EndsWith("`n",[StringComparison]::Ordinal)) { $prefix += $ending }
    $trace = "- invocation: skill=$Skill mode=adapter tool=$Tool ok=True status=delegated$ending"
    return [pscustomobject]@{ Content=$prefix+$trace+$PlanText.Substring($sectionEnd);Warning='' }
}

function Invoke-HarnessAdapterPrepareDelegation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Request)

    $body = Assert-HarnessDelegationEnvelope -Envelope $Request -MessageType request -Operation prepare_delegation
    foreach ($name in @('repo_root','workspace_root','task_id','stage','skill','tool','tool_profile_id','mode','payload_json')) {
        if ($body[$name] -isnot [string]) { throw "prepare_delegation.$name must be a string" }
    }
    if ([string]$body.task_id -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$') {
        throw "TaskId must be a lowercase slug with 1-64 letters, digits, or hyphens and must not be reserved (none, idle, unknown): $($body.task_id)"
    }
    if ($body.mode -cnotin @('readonly','writable')) { throw 'prepare_delegation contains an invalid mode' }
    $repoRoot = (Resolve-Path -LiteralPath ([string]$body.repo_root) -ErrorAction Stop).Path
    if ($script:CanonicalStages -cnotcontains [string]$body.stage) { throw "Stage is not canonical: $($body.stage)" }
    if ([string]$body.skill -cnotmatch '^[a-z][a-z0-9-]*$') { Throw-HarnessAdapterRejection -Message 'skill not in adapter whitelist' }
    if ($script:AllowedTools -cnotcontains [string]$body.tool) { throw "Unsupported Tool; expected one of: $($script:AllowedTools -join ', ')" }
    if ([string]$body.tool_profile_id) {
        $profile = Read-HarnessToolProfile -RepoRoot $repoRoot -Name ([string]$body.tool_profile_id)
        if ($profile.Backend -cne [string]$body.tool) { throw "Tool profile backend '$($profile.Backend)' does not match Tool '$($body.tool)'" }
    }
    $workspace = Resolve-HarnessDelegationWorkspace -WorkspaceRoot ([string]$body.workspace_root)
    $mutex = Enter-HarnessAdapterPlanMutex -TaskId ([string]$body.task_id)
    try {
        $paths = Resolve-HarnessDelegationTaskPaths -WorkspaceRoot $workspace -TaskId ([string]$body.task_id)
        $planText = [IO.File]::ReadAllText($paths.PlanPath,[Text.UTF8Encoding]::new($false,$true))
        $fields = Assert-HarnessAdapterPlanIdentity -Content $planText -TaskId ([string]$body.task_id) -Stage ([string]$body.stage)
        $generation = Get-HarnessAdapterPlanGeneration -Content $planText
    } finally {
        Exit-HarnessAdapterPlanMutex -Mutex $mutex
    }
    $warnings = @()
    if ($fields.Contains('skills_dir') -and -not [string]::IsNullOrWhiteSpace([string]$fields.skills_dir)) {
        $warnings += 'task-level skills_dir is reserved in Phase 3 and ignored.'
    }
    $payload = ConvertFrom-HarnessAdapterPayload -PayloadJson ([string]$body.payload_json)
    if ([string]$body.skill -ceq 'implement') {
        Throw-HarnessAdapterRejection -Message 'implement skill must be run by human; adapter refuses side-effect skills (S11 / R11)'
    }
    if ([string]$body.skill -cne 'codex') { Throw-HarnessAdapterRejection -Message 'skill not in adapter whitelist' }
    if ([string]$body.mode -cne 'readonly') { Throw-HarnessAdapterRejection -Message 'codex adapter only supports readonly mode' }
    if (-not $payload.Contains('task') -or [string]::IsNullOrWhiteSpace([string]$payload.task)) {
        throw 'PayloadJson.task is required for codex delegation.'
    }
    $skillRoot = Resolve-HarnessAdapterSkillRoot -RepoRoot $repoRoot -WorkspaceRoot $workspace -Tool ([string]$body.tool) -ToolProfileId ([string]$body.tool_profile_id)
    $backendScript = Join-Path $skillRoot 'codex\scripts\invoke_codex.ps1'
    if (-not (Test-Path -LiteralPath $backendScript -PathType Leaf)) { throw "Missing adapter target script: $backendScript" }
    $delegationId = [guid]::NewGuid().ToString('N')
    $backendOutput = Join-Path ([IO.Path]::GetTempPath()) ("invoke-harness-skill-output-$delegationId.tmp")
    $script:PreparedDelegations.Add($delegationId,[pscustomobject]@{
        WorkspaceRoot=$workspace;TaskId=[string]$body.task_id;Stage=[string]$body.stage;Skill=[string]$body.skill
        Tool=[string]$body.tool;Generation=$generation;BackendOutput=$backendOutput
    })
    $response = [ordered]@{
        schema_version='adapter-kernel-api/v1'
        message_type='response'
        body=[ordered]@{
            operation='prepare_delegation'
            delegation_id=$delegationId
            backend_script=$backendScript
            backend_output_path=$backendOutput
            backend_task=[string]$payload.task
            backend_workspace=$workspace
            backend_files=@($(if($payload.Contains('file')){@($payload.file)}else{@()}) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            backend_session=$(if($payload.Contains('session')){[string]$payload.session}else{''})
            backend_model=$(if($payload.Contains('model')){[string]$payload.model}else{''})
            backend_reasoning=$(if($payload.Contains('reasoning') -and $payload.reasoning){[string]$payload.reasoning}else{'medium'})
            backend_timeout_seconds=1800
            backend_read_only=$true
            warnings=@($warnings)
        }
    }
    [void](Assert-HarnessDelegationEnvelope -Envelope $response -MessageType response -Operation prepare_delegation)
    return $response
}

function Invoke-HarnessAdapterCommitDelegation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Request)

    $body = Assert-HarnessDelegationEnvelope -Envelope $Request -MessageType request -Operation commit_delegation
    foreach ($name in @('delegation_id','artifact_base64','session_id')) {
        if ($body[$name] -isnot [string]) { throw "commit_delegation.$name must be a string" }
    }
    if ($body.succeeded -isnot [bool] -or $body.diagnostics -isnot [Collections.IList] -or
        $body.diagnostics -is [string] -or @($body.diagnostics | Where-Object { $_ -isnot [string] }).Count) {
        throw 'commit_delegation contains an invalid result shape'
    }
    $id = [string]$body.delegation_id
    if (-not $script:PreparedDelegations.ContainsKey($id)) { throw 'delegation_id is unknown or already committed' }
    $record = $script:PreparedDelegations[$id]
    $warnings = [Collections.Generic.List[string]]::new()
    try {
        if (-not [bool]$body.succeeded) {
            $result = New-HarnessAdapterResult -Ok $false -Status error -Errors ([string[]]@($body.diagnostics))
        } else {
            try { $artifactBytes = [Convert]::FromBase64String([string]$body.artifact_base64) } catch [FormatException] {
                throw 'codex adapter backend output frame is not valid Base64'
            }
            $mutex = Enter-HarnessAdapterPlanMutex -TaskId $record.TaskId
            $tempPath = ''
            try {
                $paths = Resolve-HarnessDelegationTaskPaths -WorkspaceRoot $record.WorkspaceRoot -TaskId $record.TaskId
                $planText = [IO.File]::ReadAllText($paths.PlanPath,[Text.UTF8Encoding]::new($false,$true))
                [void](Assert-HarnessAdapterPlanIdentity -Content $planText -TaskId $record.TaskId -Stage $record.Stage)
                if ((Get-HarnessAdapterPlanGeneration -Content $planText) -cne $record.Generation) {
                    throw 'plan.md generation changed while adapter backend was running; stale result was discarded.'
                }
                $leaf = 'codex-{0}-{1}.md' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff'),[guid]::NewGuid().ToString('N')
                $finalPath = Resolve-HarnessDelegationContainedPath -Root $record.WorkspaceRoot -Path "$($paths.TaskRelativePath)/$leaf" -Label 'codex artifact' -AllowMissing
                $tempPath = Resolve-HarnessDelegationContainedPath -Root $record.WorkspaceRoot -Path "$($paths.TaskRelativePath)/.$leaf.$([guid]::NewGuid().ToString('N')).tmp" -Label 'codex artifact temp' -AllowMissing
                $stream = [IO.FileStream]::new($tempPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
                try { $stream.Write($artifactBytes,0,$artifactBytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
                $publishText = [IO.File]::ReadAllText($paths.PlanPath,[Text.UTF8Encoding]::new($false,$true))
                [void](Assert-HarnessAdapterPlanIdentity -Content $publishText -TaskId $record.TaskId -Stage $record.Stage)
                if ((Get-HarnessAdapterPlanGeneration -Content $publishText) -cne $record.Generation) {
                    throw 'plan.md generation changed while adapter backend was running; stale result was discarded.'
                }
                [IO.File]::Move($tempPath,$finalPath)
                $tempPath = ''
                try {
                    $trace = Add-HarnessAdapterInvocationTrace -PlanText $publishText -Stage $record.Stage -Skill $record.Skill -Tool $record.Tool
                    if ($trace -is [string]) { $warnings.Add($trace) }
                    elseif ($null -ne $trace) { Write-HarnessAdapterPlanAtomic -Path $paths.PlanPath -Content $trace.Content }
                } catch {
                    $warnings.Add("invocation trace skipped: $($_.Exception.Message)")
                }
                $handoff = if ([string]::IsNullOrWhiteSpace([string]$body.session_id)) { '' } else { "session_id=$($body.session_id)" }
                $result = New-HarnessAdapterResult -Ok $true -Status delegated -ArtifactPaths @($finalPath) -Handoff $handoff
            } finally {
                if ($tempPath -and [IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
                Exit-HarnessAdapterPlanMutex -Mutex $mutex
            }
        }
        $response = [ordered]@{
            schema_version='adapter-kernel-api/v1'
            message_type='response'
            body=[ordered]@{operation='commit_delegation';result=$result;warnings=$warnings.ToArray()}
        }
        [void](Assert-HarnessDelegationEnvelope -Envelope $response -MessageType response -Operation commit_delegation)
        return $response
    } finally {
        [void]$script:PreparedDelegations.Remove($id)
        if ($record.BackendOutput -and [IO.File]::Exists($record.BackendOutput)) {
            try { [IO.File]::Delete($record.BackendOutput) } catch { }
        }
    }
}

Export-ModuleMember -Function Invoke-HarnessAdapterPrepareDelegation,Invoke-HarnessAdapterCommitDelegation
