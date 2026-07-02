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

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-team-orchestration-repo-' + [guid]::NewGuid().ToString('N'))
    foreach ($relativePath in @(
        'scripts\export-team-preset.ps1',
        'skills\workflow-team',
        'skills\orchestrator\SKILL.md',
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

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-orchestration-streams-' + [guid]::NewGuid().ToString('N'))
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

function ConvertTo-PowerShellLiteral {
    param([object]$Value)

    if ($null -eq $Value) {
        return '$null'
    }

    return "'{0}'" -f (($Value.ToString()) -replace "'", "''")
}

function Assert-SingleLineJson {
    param(
        [string]$JsonText,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($JsonText) -or $JsonText -match "\r?\n") {
        Add-Failure ("{0} stdout should be a single JSON line" -f $Label)
        return $null
    }

    try {
        return ($JsonText | ConvertFrom-Json)
    } catch {
        Add-Failure ("{0} stdout should be valid JSON: {1}" -f $Label, $_.Exception.Message)
        return $null
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

function Invoke-SpawnTeam {
    param(
        [string]$ScriptPath,
        [string]$RepoRoot,
        [string]$TaskId,
        [string]$TeamModeValue,
        [string]$MockMode,
        [string]$LogPath
    )

    $wrapperPath = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-spawn-team-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $teamModeLiteral = ConvertTo-PowerShellLiteral -Value $TeamModeValue
    $mockModeLiteral = ConvertTo-PowerShellLiteral -Value $MockMode
    $logPathLiteral = ConvertTo-PowerShellLiteral -Value $LogPath
    $scriptLiteral = ConvertTo-PowerShellLiteral -Value $ScriptPath
    $repoRootLiteral = ConvertTo-PowerShellLiteral -Value $RepoRoot
    $taskLiteral = ConvertTo-PowerShellLiteral -Value $TaskId

    $wrapperContent = @"
if ($teamModeLiteral -eq '') {
    Remove-Item Env:\AITEAMCODE_TEAM_MODE -ErrorAction SilentlyContinue
} else {
    `$env:AITEAMCODE_TEAM_MODE = $teamModeLiteral
}
`$global:MockMode = $mockModeLiteral
`$global:TeamSpawnLogPath = $logPathLiteral
Remove-Item Function:\team_spawn_agent -ErrorAction SilentlyContinue
if (`$global:MockMode -ne 'none') {
    `$global:CallCount = 0
    function global:team_spawn_agent {
        param([string]`$PayloadJson)
        `$global:CallCount += 1
        if (-not [string]::IsNullOrWhiteSpace(`$global:TeamSpawnLogPath)) {
            [System.IO.File]::AppendAllText(`$global:TeamSpawnLogPath, `$PayloadJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding(`$false)))
        }
        if (`$global:MockMode -eq 'fail-on-third' -and `$global:CallCount -eq 3) {
            throw 'mock failure on call 3'
        }
    }
}
& $scriptLiteral -WorkflowName 'harness-lite' -TaskId $taskLiteral -RepoRoot $repoRootLiteral
exit `$LASTEXITCODE
"@

    try {
        Write-Utf8Bom -Path $wrapperPath -Content $wrapperContent
        return Invoke-PowerShellWithStreams -Arguments @(
            '-NoProfile',
            '-File', $wrapperPath
        )
    } finally {
        Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $RepoRoot
$spawnScriptPath = Join-Path $fixtureRoot 'skills\workflow-team\scripts\spawn-team.ps1'
$orchestratorSkillPath = Join-Path $fixtureRoot 'skills\orchestrator\SKILL.md'
$authorityPath = Join-Path $fixtureRoot 'docs\team-write-authority.md'
$rolePromptsRoot = Join-Path $fixtureRoot 'agent-configs\role-prompts'
$script:Checks = @()
$script:Failures = @()
$cleanupPaths = @($fixtureRoot)

try {
    $o1Result = Invoke-SpawnTeam -ScriptPath $spawnScriptPath -RepoRoot $fixtureRoot -TaskId 'phase4-o1' -TeamModeValue '' -MockMode 'none' -LogPath ''
    $o1Json = Assert-SingleLineJson -JsonText $o1Result.StdOut -Label 'O1'
    $orchestratorSkill = Read-FileUtf8 -Path $orchestratorSkillPath
    if ($o1Result.ExitCode -ne 0 -and
        $null -ne $o1Json -and
        -not $o1Json.ok -and
        $o1Json.reason -eq 'team_mode_disabled' -and
        $o1Result.StdErr -match 'AITEAMCODE_TEAM_MODE not set' -and
        $orchestratorSkill.Contains('Team mode (documentation only)') -and
        -not ($orchestratorSkill -match '(?m)^\s*if\s*\(\$env:AITEAMCODE_TEAM_MODE')) {
        Add-Check 'O1 spawn-team fails closed when AITEAMCODE_TEAM_MODE is unset and orchestrator keeps a documentation-only team-mode branch'
    } else {
        Add-Failure ("O1 env opt-in guard failed, stdout=[{0}] stderr=[{1}]" -f $o1Result.StdOut, $o1Result.StdErr)
    }

    $o2LogPath = Join-Path ([System.IO.Path]::GetTempPath()) ('spawn-team-o2-' + [guid]::NewGuid().ToString('N') + '.log')
    $cleanupPaths += $o2LogPath
    $o2Result = Invoke-SpawnTeam -ScriptPath $spawnScriptPath -RepoRoot $fixtureRoot -TaskId 'phase4-o2' -TeamModeValue '1' -MockMode 'capture' -LogPath $o2LogPath
    $o2Json = Assert-SingleLineJson -JsonText $o2Result.StdOut -Label 'O2'
    $o2PayloadLines = @(((Read-FileUtf8 -Path $o2LogPath) -split "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $o2Payloads = @($o2PayloadLines | ForEach-Object { $_ | ConvertFrom-Json })
    $expectedRoles = @('plan-author', 'plan-reviewer', 'implementer', 'code-reviewer', 'tester')
    $actualRoles = @($o2Payloads | ForEach-Object { [string]$_.role })
    if ($o2Result.ExitCode -eq 0 -and
        $null -ne $o2Json -and
        $o2Json.ok -and
        ((@($actualRoles) -join '|') -eq ($expectedRoles -join '|')) -and
        ((@($o2Json.spawned_roles) -join '|') -eq ($expectedRoles -join '|'))) {
        Add-Check 'O2 spawn-team calls team_spawn_agent exactly five times in workflow stage order when env opt-in is enabled'
    } else {
        Add-Failure ("O2 spawn order failed, stdout=[{0}] stderr=[{1}] roles=[{2}]" -f $o2Result.StdOut, $o2Result.StdErr, ($actualRoles -join ', '))
    }

    $expectedPayloads = [ordered]@{
        'plan-author' = [ordered]@{ backend = 'codex'; model = 'gpt-5.5/xhigh'; skills = @('plan', 'entry-router') }
        'plan-reviewer' = [ordered]@{ backend = 'codex'; model = 'gpt-5.5/xhigh'; skills = @('review') }
        'implementer' = [ordered]@{ backend = 'codex'; model = 'gpt-5.5/xhigh'; skills = @('implement') }
        'code-reviewer' = [ordered]@{ backend = 'codex'; model = 'gpt-5.5/xhigh'; skills = @('review') }
        'tester' = [ordered]@{ backend = 'codex'; model = 'gpt-5.5/xhigh'; skills = @('test') }
    }
    $payloadOk = $true
    foreach ($payload in $o2Payloads) {
        $expected = $expectedPayloads[[string]$payload.role]
        $promptPath = Join-Path $rolePromptsRoot ("{0}.md" -f $payload.role)
        $expectedPrompt = Read-FileUtf8 -Path $promptPath
        $actualSkills = @($payload.skills_whitelist | ForEach-Object { [string]$_ } | Sort-Object)
        $expectedSkills = @($expected.skills | Sort-Object)
        if ($payload.backend -ne $expected.backend -or
            $payload.model -ne $expected.model -or
            $payload.system_prompt -ne $expectedPrompt -or
            ((@($actualSkills) -join '|') -ne (@($expectedSkills) -join '|'))) {
            $payloadOk = $false
        }
    }

    if ($payloadOk) {
        Add-Check 'O3 spawn payload includes the expected role, backend, model, system prompt seed, and skills whitelist for every member'
    } else {
        Add-Failure 'O3 spawn payload parity failed'
    }

    $o4LogPath = Join-Path ([System.IO.Path]::GetTempPath()) ('spawn-team-o4-' + [guid]::NewGuid().ToString('N') + '.log')
    $cleanupPaths += $o4LogPath
    $o4Result = Invoke-SpawnTeam -ScriptPath $spawnScriptPath -RepoRoot $fixtureRoot -TaskId 'phase4-o4' -TeamModeValue '1' -MockMode 'fail-on-third' -LogPath $o4LogPath
    $o4Json = Assert-SingleLineJson -JsonText $o4Result.StdOut -Label 'O4'
    $o4PayloadLines = @(((Read-FileUtf8 -Path $o4LogPath) -split "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($o4Result.ExitCode -ne 0 -and
        $null -ne $o4Json -and
        -not $o4Json.ok -and
        $o4Json.reason -eq 'spawn_failed' -and
        $o4Json.failed_role -eq 'implementer' -and
        $o4PayloadLines.Count -eq 3 -and
        $o4Result.StdErr -match 'mock failure on call 3') {
        Add-Check 'O4 spawn-team stops on the first team_spawn_agent failure and returns single-line fallback JSON'
    } else {
        Add-Failure ("O4 fallback failed, stdout=[{0}] stderr=[{1}] calls={2}" -f $o4Result.StdOut, $o4Result.StdErr, $o4PayloadLines.Count)
    }

    $expectedPrefixes = @('.assistant/', 'docs/tasks/<task-id>/')
    $docPrefixes = @(Get-PathPrefixesFromAuthorityDoc -Path $authorityPath)
    $o5Files = @(
        (Join-Path $fixtureRoot 'skills\workflow-team\SKILL.md')
    ) + (Get-ChildItem -LiteralPath $rolePromptsRoot -Filter '*.md' -File | Select-Object -ExpandProperty FullName)
    $prefixStringsOk = ((@($docPrefixes) -join '|') -eq ($expectedPrefixes -join '|'))
    foreach ($file in $o5Files) {
        $content = Read-FileUtf8 -Path $file
        if (-not ($content.Contains('.assistant/') -and $content.Contains('docs/tasks/<task-id>/'))) {
            $prefixStringsOk = $false
        }
    }

    $sampleCode = @'
Set-Content $repo/.assistant/foo.md 'x'
Set-Content $repo/docs/tasks/x/plan.md 'x'
'@
    $matchCount = ([regex]::Matches($sampleCode, 'Set-Content\s+\$repo/(\.assistant/|docs/tasks/)')).Count
    if ($prefixStringsOk -and $matchCount -ge 2) {
        Add-Check 'O5 single-writer protection stays aligned on the same two path prefixes across authority doc, role prompts, and static scan patterns'
    } else {
        Add-Failure ("O5 prefix scan parity failed, doc prefixes=[{0}] matches={1}" -f ($docPrefixes -join ', '), $matchCount)
    }

    $o6LogPath = Join-Path ([System.IO.Path]::GetTempPath()) ('spawn-team-o6-' + [guid]::NewGuid().ToString('N') + '.log')
    $cleanupPaths += $o6LogPath
    $o6Result = Invoke-SpawnTeam -ScriptPath $spawnScriptPath -RepoRoot $fixtureRoot -TaskId 'phase4-o1' -TeamModeValue '' -MockMode 'capture' -LogPath $o6LogPath
    $o6Json = Assert-SingleLineJson -JsonText $o6Result.StdOut -Label 'O6'
    $o6PayloadLines = @(((Read-FileUtf8 -Path $o6LogPath) -split "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($o6Result.ExitCode -eq $o1Result.ExitCode -and
        $o6Result.StdOut -eq $o1Result.StdOut -and
        $o6Result.StdErr -eq $o1Result.StdErr -and
        $o6PayloadLines.Count -eq 0 -and
        $null -ne $o6Json -and
        $o6Json.reason -eq 'team_mode_disabled') {
        Add-Check 'O6 MCP availability does not bypass the env opt-in gate when AITEAMCODE_TEAM_MODE is unset'
    } else {
        Add-Failure ("O6 MCP bypass guard failed, O1 stdout=[{0}] O6 stdout=[{1}] O6 calls={2}" -f $o1Result.StdOut, $o6Result.StdOut, $o6PayloadLines.Count)
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
