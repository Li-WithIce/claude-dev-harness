[CmdletBinding()]
param(
    [string]$Workflow = 'harness-lite',

    [Parameter(Mandatory = $true)]
    [string]$Output,

    [ValidateSet('yaml', 'json')]
    [string]$Format = 'yaml',

    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ReadOnlyPathPrefixes = @('.assistant/', 'docs/tasks/<task-id>/')

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
} else {
    $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
}

function Write-Diagnostic {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        [Console]::Error.WriteLine($Message)
    }
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Split-InlineYamlList {
    param([string]$Value)

    $normalized = $Value.Trim()
    if ($normalized -notmatch '^\[(.*)\]$') {
        throw ("Unsupported inline YAML list: {0}" -f $Value)
    }

    $inner = $Matches[1].Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) {
        return @()
    }

    $items = @()
    foreach ($item in ($inner -split ',')) {
        $trimmed = $item.Trim().Trim('"').Trim("'")
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $items += $trimmed
        }
    }

    return $items
}

function Read-WorkflowDescriptor {
    param(
        [string]$RepoRoot,
        [string]$WorkflowName
    )

    if ([string]::IsNullOrWhiteSpace($WorkflowName)) {
        throw 'Workflow name is empty.'
    }

    $descriptorPath = Join-Path (Join-Path $RepoRoot 'agent-configs\workflows') ("{0}.yaml" -f $WorkflowName.Trim())
    if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        throw ("Missing workflow descriptor: {0}" -f $descriptorPath)
    }

    $descriptor = [ordered]@{
        Name = ''
        Version = ''
        Stages = [ordered]@{}
        Path = $descriptorPath
    }

    $sawStages = $false
    $currentStage = ''
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $descriptorPath -Encoding utf8)) {
        $lineNumber += 1
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($line -match '^name:\s*(.+?)\s*$') {
            $descriptor.Name = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^version:\s*(.+?)\s*$') {
            $descriptor.Version = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^stages:\s*$') {
            $sawStages = $true
            $currentStage = ''
            continue
        }

        if ($line -match '^\s{2}([A-Z_]+):\s*$') {
            $currentStage = $Matches[1]
            if ($descriptor.Stages.Contains($currentStage)) {
                throw ("Workflow descriptor duplicates stage {0} at line {1}" -f $currentStage, $lineNumber)
            }

            $descriptor.Stages[$currentStage] = [ordered]@{
                Role = ''
                DefaultProfile = ''
                SkillsWhitelist = @()
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentStage)) {
            throw ("Unsupported workflow descriptor line {0}: {1}" -f $lineNumber, $line)
        }

        if ($line -match '^\s{4}role:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['Role'] = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^\s{4}default_profile:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['DefaultProfile'] = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^\s{4}skills_whitelist:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['SkillsWhitelist'] = @(Split-InlineYamlList -Value $Matches[1])
            continue
        }

        throw ("Unsupported workflow descriptor line {0}: {1}" -f $lineNumber, $line)
    }

    if ([string]::IsNullOrWhiteSpace($descriptor.Name)) {
        throw 'Workflow descriptor is missing name.'
    }

    if ([string]::IsNullOrWhiteSpace($descriptor.Version)) {
        throw 'Workflow descriptor is missing version.'
    }

    if (-not $sawStages) {
        throw 'Workflow descriptor is missing stages.'
    }

    return [pscustomobject]@{
        Name = $descriptor.Name
        Version = $descriptor.Version
        Stages = $descriptor.Stages
        Path = $descriptor.Path
    }
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

    foreach ($required in @('name', 'backend', 'model')) {
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
        Model = $fields['model']
        SkillsDirs = @($listFields['skills_dirs'])
        Path = $profilePath
    }
}

function ConvertTo-PresetYaml {
    param([System.Collections.IDictionary]$Preset)

    $lines = @(
        ('name: {0}' -f $Preset['name']),
        ('version: {0}' -f $Preset['version']),
        'single_writer:',
        ('  owner: {0}' -f $Preset['single_writer']['owner']),
        '  members_read_only_path_prefixes:'
    )

    foreach ($prefix in @($Preset['single_writer']['members_read_only_path_prefixes'])) {
        $lines += ('    - {0}' -f $prefix)
    }

    $lines += 'members:'
    foreach ($member in @($Preset['members'])) {
        $skillsLiteral = '[{0}]' -f ((@($member['skills_whitelist'])) -join ', ')
        $lines += ('  - role: {0}' -f $member['role'])
        $lines += ('    backend: {0}' -f $member['backend'])
        $lines += ('    model: {0}' -f $member['model'])
        $lines += ('    skills_whitelist: {0}' -f $skillsLiteral)
        $lines += ('    role_prompt_ref: {0}' -f $member['role_prompt_ref'])
    }

    return (($lines -join "`r`n") + "`r`n")
}

$tempPath = ''
try {
    $workflowDescriptor = Read-WorkflowDescriptor -RepoRoot $RepoRoot -WorkflowName $Workflow
    $members = New-Object System.Collections.Generic.List[object]
    foreach ($stageName in $workflowDescriptor.Stages.Keys) {
        $stage = $workflowDescriptor.Stages[$stageName]
        if ([string]::IsNullOrWhiteSpace($stage['Role'])) {
            throw ("Workflow stage {0} is missing role." -f $stageName)
        }

        if ([string]::IsNullOrWhiteSpace($stage['DefaultProfile'])) {
            throw ("Workflow stage {0} is missing default_profile." -f $stageName)
        }

        $profile = Read-ToolProfileDescriptor -RepoRoot $RepoRoot -Name $stage['DefaultProfile']
        $rolePromptRef = ('agent-configs/role-prompts/{0}.md' -f $stage['Role'])
        $rolePromptPath = Join-Path (Join-Path $RepoRoot 'agent-configs\role-prompts') ("{0}.md" -f $stage['Role'])
        if (-not (Test-Path -LiteralPath $rolePromptPath -PathType Leaf)) {
            throw ("Missing role prompt: {0}" -f $rolePromptPath)
        }

        $skillsDir = if (@($profile.SkillsDirs).Count -gt 0) { [string]$profile.SkillsDirs[0] } else { '' }
        Write-Diagnostic ("resolved profile={0} backend={1} model={2} role={3} skills_dir={4}" -f $profile.Name, $profile.Backend, $profile.Model, $stage['Role'], $skillsDir)

        $members.Add([ordered]@{
            role = [string]$stage['Role']
            backend = [string]$profile.Backend
            model = [string]$profile.Model
            skills_whitelist = @($stage['SkillsWhitelist'])
            role_prompt_ref = $rolePromptRef
        })
    }

    $preset = [ordered]@{
        name = $workflowDescriptor.Name
        version = 1
        single_writer = [ordered]@{
            owner = 'leader'
            members_read_only_path_prefixes = @($ReadOnlyPathPrefixes)
        }
        members = @($members.ToArray())
    }

    $outputPath = [System.IO.Path]::GetFullPath($Output)
    $outputDirectory = Split-Path -Parent $outputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    $tempPath = Join-Path $outputDirectory ((Split-Path -Leaf $outputPath) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    $content = if ($Format -eq 'json') {
        ($preset | ConvertTo-Json -Depth 8)
    } else {
        ConvertTo-PresetYaml -Preset $preset
    }
    Write-Utf8NoBom -Path $tempPath -Content $content
    Move-Item -LiteralPath $tempPath -Destination $outputPath -Force
    $tempPath = ''

    [Console]::Out.WriteLine(("team-preset written to {0}" -f $outputPath))
    exit 0
} catch {
    if (-not [string]::IsNullOrWhiteSpace($tempPath) -and (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }

    Write-Diagnostic $_.Exception.Message
    exit 1
}
