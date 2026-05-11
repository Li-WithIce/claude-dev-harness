[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding utf8)
}

function Remove-DirectoryWithRetry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 200
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Add-Failure ("cleanup failed for {0}: {1}" -f $Path, $lastError.Exception.Message)
    }
}

function Copy-RepoPathToFixture {
    param(
        [string]$SourceRoot,
        [string]$FixtureRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $destinationPath = Join-Path $FixtureRoot $RelativePath
    $destinationParent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-team-preset-repo-' + [guid]::NewGuid().ToString('N'))
    foreach ($relativePath in @(
        'scripts\export-team-preset.ps1',
        'agent-configs\profiles',
        'agent-configs\workflows',
        'agent-configs\role-prompts',
        'docs\team-write-authority.md'
    )) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath $relativePath
    }

    return $fixtureRoot
}

function Invoke-PowerShellWithStreams {
    param([string[]]$Arguments)

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-preset-streams-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
    $stdoutPath = Join-Path $streamRoot 'stdout.txt'
    $stderrPath = Join-Path $streamRoot 'stderr.txt'

    try {
        $shellPath = (Get-Process -Id $PID).Path
        $process = Start-Process -FilePath $shellPath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout.Trim()
            StdErr = $stderr.Trim()
        }
    } finally {
        Remove-DirectoryWithRetry -Path $streamRoot
    }
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
    param([string]$Path)

    $descriptor = [ordered]@{
        Name = ''
        Version = ''
        Stages = [ordered]@{}
    }

    $currentStage = ''
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($line -match '^name:\s*(.+?)\s*$') {
            $descriptor.Name = $Matches[1].Trim()
            continue
        }

        if ($line -match '^version:\s*(.+?)\s*$') {
            $descriptor.Version = $Matches[1].Trim()
            continue
        }

        if ($line -match '^\s{2}([A-Z_]+):\s*$') {
            $currentStage = $Matches[1]
            $descriptor.Stages[$currentStage] = [ordered]@{
                Role = ''
                DefaultProfile = ''
                SkillsWhitelist = @()
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentStage)) {
            continue
        }

        if ($line -match '^\s{4}role:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['Role'] = $Matches[1].Trim()
            continue
        }

        if ($line -match '^\s{4}default_profile:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['DefaultProfile'] = $Matches[1].Trim()
            continue
        }

        if ($line -match '^\s{4}skills_whitelist:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['SkillsWhitelist'] = @(Split-InlineYamlList -Value $Matches[1])
        }
    }

    return $descriptor
}

function Read-ProfileDescriptor {
    param([string]$Path)

    $fields = @{}
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        if ($line -match '^([a-z_]+):\s*(.+?)\s*$') {
            $fields[$Matches[1]] = $Matches[2].Trim()
        }
    }

    return [pscustomobject]@{
        Backend = [string]$fields['backend']
        Model = [string]$fields['model']
    }
}

function Get-PathPrefixesFromAuthorityDoc {
    param([string]$Path)

    $content = Read-FileUtf8 -Path $Path
    if ($content -notmatch "(?ms)^## Member read-only path prefixes\r?\n(.*?)(?=^## |\z)") {
        return @()
    }

    $prefixes = @()
    foreach ($line in ($Matches[1] -split "\r?\n")) {
        if ($line -match '^\s*-\s+`?(.+?)`?\s*$') {
            $prefixes += $Matches[1]
        }
    }

    return @($prefixes)
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $RepoRoot
$scriptPath = Join-Path $fixtureRoot 'scripts\export-team-preset.ps1'
$workflowPath = Join-Path $fixtureRoot 'agent-configs\workflows\harness-lite.yaml'
$authorityPath = Join-Path $fixtureRoot 'docs\team-write-authority.md'
$script:Checks = @()
$script:Failures = @()
$cleanupPaths = @($fixtureRoot)

try {
    $jsonOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('team-preset-' + [guid]::NewGuid().ToString('N') + '.json')
    $yamlOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('team-preset-' + [guid]::NewGuid().ToString('N') + '.yaml')
    $cleanupPaths += @($jsonOutputPath, $yamlOutputPath)

    $jsonResult = Invoke-PowerShellWithStreams -Arguments @(
        '-NoProfile',
        '-File', $scriptPath,
        '-Workflow', 'harness-lite',
        '-Output', $jsonOutputPath,
        '-Format', 'json',
        '-RepoRoot', $fixtureRoot
    )
    $yamlResult = Invoke-PowerShellWithStreams -Arguments @(
        '-NoProfile',
        '-File', $scriptPath,
        '-Workflow', 'harness-lite',
        '-Output', $yamlOutputPath,
        '-RepoRoot', $fixtureRoot
    )

    $jsonText = Read-FileUtf8 -Path $jsonOutputPath
    $yamlText = Read-FileUtf8 -Path $yamlOutputPath
    $preset = $null
    try {
        $preset = $jsonText | ConvertFrom-Json
    } catch {
        Add-Failure ("P1 preset JSON should parse: {0}" -f $_.Exception.Message)
    }

    if ($jsonResult.ExitCode -eq 0 -and
        $yamlResult.ExitCode -eq 0 -and
        $jsonResult.StdOut -match 'team-preset written to' -and
        $yamlResult.StdOut -match 'team-preset written to' -and
        $null -ne $preset -and
        $preset.name -eq 'harness-lite' -and
        $preset.version -eq 1 -and
        $preset.single_writer.owner -eq 'leader' -and
        $yamlText -match '^name: harness-lite' -and
        $yamlText -match 'members_read_only_path_prefixes:') {
        Add-Check 'P1 export-team-preset emits valid JSON/YAML with the expected top-level schema'
    } else {
        Add-Failure ("P1 preset export failed, json stdout=[{0}] stderr=[{1}] yaml stdout=[{2}] stderr=[{3}]" -f $jsonResult.StdOut, $jsonResult.StdErr, $yamlResult.StdOut, $yamlResult.StdErr)
    }

    $workflowDescriptor = Read-WorkflowDescriptor -Path $workflowPath
    if ($null -eq $preset) {
        Add-Failure 'P2-P5 skipped because preset export did not produce parseable JSON'
    } else {
        $expectedRoles = @($workflowDescriptor.Stages.Keys | ForEach-Object { [string]$workflowDescriptor.Stages[$_]['Role'] })
        $actualRoles = @($preset.members | ForEach-Object { [string]$_.role })
        if ($actualRoles.Count -eq 5 -and ((@($actualRoles) -join '|') -eq (@($expectedRoles) -join '|'))) {
            Add-Check 'P2 preset members preserve the five workflow roles in stage order'
        } else {
            Add-Failure ("P2 preset roles mismatch: expected [{0}] got [{1}]" -f ($expectedRoles -join ', '), ($actualRoles -join ', '))
        }

        $profileParityOk = $true
        foreach ($stageName in $workflowDescriptor.Stages.Keys) {
            $stage = $workflowDescriptor.Stages[$stageName]
            $member = @($preset.members | Where-Object { $_.role -eq $stage['Role'] })[0]
            if ($null -eq $member) {
                $profileParityOk = $false
                continue
            }

            $profilePath = Join-Path $fixtureRoot ("agent-configs\profiles\{0}.yaml" -f $stage['DefaultProfile'])
            $profile = Read-ProfileDescriptor -Path $profilePath
            if ($member.backend -ne $profile.Backend -or $member.model -ne $profile.Model) {
                $profileParityOk = $false
            }
        }

        if ($profileParityOk) {
            Add-Check 'P3 preset backend/model values match each stage default_profile descriptor'
        } else {
            Add-Failure 'P3 preset backend/model parity with default_profile descriptors failed'
        }

        $whitelistParityOk = $true
        foreach ($stageName in $workflowDescriptor.Stages.Keys) {
            $stage = $workflowDescriptor.Stages[$stageName]
            $member = @($preset.members | Where-Object { $_.role -eq $stage['Role'] })[0]
            if ($null -eq $member) {
                $whitelistParityOk = $false
                continue
            }

            $expected = @($stage['SkillsWhitelist'] | Sort-Object)
            $actual = @($member.skills_whitelist | ForEach-Object { [string]$_ } | Sort-Object)
            if ((@($expected) -join '|') -ne (@($actual) -join '|')) {
                $whitelistParityOk = $false
            }
        }

        if ($whitelistParityOk) {
            Add-Check 'P4 preset skills_whitelist matches harness-lite workflow descriptor for every stage'
        } else {
            Add-Failure 'P4 preset skills_whitelist parity failed'
        }

        $expectedPrefixes = @('.assistant/', 'docs/tasks/<task-id>/')
        $docPrefixes = @(Get-PathPrefixesFromAuthorityDoc -Path $authorityPath)
        $rolePromptRefsOk = $true
        foreach ($member in @($preset.members)) {
            $rolePromptPath = Join-Path $fixtureRoot (([string]$member.role_prompt_ref) -replace '/', '\')
            if (-not (Test-Path -LiteralPath $rolePromptPath -PathType Leaf)) {
                $rolePromptRefsOk = $false
            }
        }

        if ($rolePromptRefsOk -and
            ((@($preset.single_writer.members_read_only_path_prefixes) -join '|') -eq ($expectedPrefixes -join '|')) -and
            ((@($docPrefixes) -join '|') -eq ($expectedPrefixes -join '|'))) {
            Add-Check 'P5 role_prompt_ref paths exist and the read-only path prefixes stay byte-identical across preset and authority doc'
        } else {
            Add-Failure ("P5 role_prompt_ref/prefix parity failed: preset prefixes=[{0}] doc prefixes=[{1}]" -f ((@($preset.single_writer.members_read_only_path_prefixes)) -join ', '), ($docPrefixes -join ', '))
        }
    }
} finally {
    foreach ($path in $cleanupPaths) {
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path).PSIsContainer) {
                Remove-DirectoryWithRetry -Path $path
            } else {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Output 'Checks:'
foreach ($check in $script:Checks) {
    Write-Output ('- {0}' -f $check)
}
Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($failure in $script:Failures) {
        Write-Output ('- {0}' -f $failure)
    }
    exit 1
}
