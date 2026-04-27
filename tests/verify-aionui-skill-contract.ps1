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

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
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

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-contract-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    foreach ($relativePath in @(
        'scripts\invoke-harness-skill.ps1',
        'scripts\generate-skills-index.ps1',
        'scripts\validate-lite-artifacts.ps1',
        'agent-configs\profiles',
        'agent-configs\workflows',
        'skills\review',
        'skills\test',
        'skills\gemini-designer-main'
    )) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath $relativePath
    }

    return $fixtureRoot
}

function New-PlanContent {
    param(
        [string]$TaskId,
        [string]$Stage = 'PLAN_REVIEW',
        [string]$Tool = 'codex',
        [switch]$IncludePlanReviewRun,
        [switch]$IncludeCodeReviewRun,
        [string[]]$ExtraFrontmatter = @()
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'
    $extra = if ($ExtraFrontmatter.Count -gt 0) {
        ($ExtraFrontmatter -join "`r`n") + "`r`n"
    } else {
        ""
    }

    $planReviewBlock = if ($IncludePlanReviewRun) {
@"
### Run 1 · 2026-04-25 10:00 · runner: harness-reviewer
- verdict: pass
- findings: none
- next: none
"@
    } else {
        ""
    }

    $codeReviewBlock = if ($IncludeCodeReviewRun) {
@"
### Run 1 · 2026-04-25 10:05 · runner: harness-reviewer
- verdict: pass
- findings: none
- next: none
"@
    } else {
        ""
    }

@"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
${extra}updated: $updatedDate
---
# Skill Contract Fixture

## Clarification
- 验收标准: adapter output stays machine-readable.
- 非目标: no team preset bridge.
- 受影响目录: scripts/, tests/, skills/, agent-configs/
- 回滚策略: remove Phase 3 adapter artifacts.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- Add ACP-style skill adapter coverage.

## Verification
- ``pwsh -File tests/verify-aionui-skill-contract.ps1``

## Risks
- none

## Plan Review
$planReviewBlock

## Implementation Notes

## Code Review
$codeReviewBlock

"@
}

function Invoke-PowerShellWithStreams {
    param([string[]]$Arguments)

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-contract-streams-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
    $stdoutPath = Join-Path $streamRoot 'stdout.txt'
    $stderrPath = Join-Path $streamRoot 'stderr.txt'

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }
        $stdout = $stdout.Trim()
        $stderr = $stderr.Trim()
        $combined = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $combined += $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $combined += $stderr
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Combined = ($combined -join "`n")
        }
    } finally {
        Remove-DirectoryWithRetry -Path $streamRoot
    }
}

function Invoke-Adapter {
    param(
        [string]$AdapterPath,
        [string]$TaskId,
        [string]$Stage,
        [string]$Skill,
        [string]$Tool,
        [string]$ToolProfileId = '',
        [string]$WorkspaceRoot,
        [string]$ArtifactRoot,
        [string]$Mode = 'readonly',
        [string]$PayloadJson = '{}'
    )

    $wrapperPath = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-adapter-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $toolProfileArgument = if ([string]::IsNullOrWhiteSpace($ToolProfileId)) { '' } else { " -ToolProfileId '$ToolProfileId'" }
    $wrapperContent = @"
& '$AdapterPath' -TaskId '$TaskId' -Stage '$Stage' -Skill '$Skill' -Tool '$Tool'$toolProfileArgument -WorkspaceRoot '$WorkspaceRoot' -ArtifactRoot '$ArtifactRoot' -Mode '$Mode' -PayloadJson @'
$PayloadJson
'@
exit `$LASTEXITCODE
"@

    try {
        Write-Utf8Bom -Path $wrapperPath -Content $wrapperContent
        return Invoke-PowerShellWithStreams -Arguments @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $wrapperPath
        )
    } finally {
        Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Validator {
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot
    )

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ValidatorPath -TaskId $TaskId -RepoRoot $RepoRoot 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = ($output -join "`n")
    }
}

function Invoke-GenerateSkillsIndex {
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$Stage,
        [string]$BackendHint,
        [string]$RepoRoot
    )

    Push-Location $RepoRoot
    try {
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -TaskId $TaskId -Stage $Stage -BackendHint $BackendHint 2>&1 | ForEach-Object { [string]$_ })
    } finally {
        Pop-Location
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
        Text = ($output -join "`n")
    }
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

function Write-MockCodexSkill {
    param(
        [string]$SkillRoot,
        [string]$Marker
    )

    $scriptPath = Join-Path $SkillRoot 'codex\scripts\ask_codex.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $scriptPath) -Force | Out-Null
    Write-Utf8Bom -Path $scriptPath -Content @"
[CmdletBinding()]
param(
    [string]`$Task,
    [string]`$Workspace,
    [string[]]`$File,
    [string]`$Session,
    [string]`$Model,
    [string]`$Reasoning = 'medium',
    [switch]`$ReadOnly,
    [string]`$Output
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$record = [ordered]@{
    marker = '$Marker'
    task = `$Task
    workspace = `$Workspace
    file = @(`$File)
    session = `$Session
    model = `$Model
    reasoning = `$Reasoning
    read_only = `$ReadOnly.IsPresent
    output = `$Output
}
`$recordPath = Join-Path (Split-Path -Parent `$Output) 'codex-call.json'
[System.IO.File]::WriteAllText(`$recordPath, ((`$record | ConvertTo-Json -Depth 5 -Compress)), (New-Object System.Text.UTF8Encoding(`$false)))
if (-not [string]::IsNullOrWhiteSpace(`$Output)) {
    [System.IO.File]::WriteAllText(`$Output, 'mock codex output', (New-Object System.Text.UTF8Encoding(`$false)))
}
Write-Output 'session_id=mock-session'
Write-Output ('output_path={0}' -f `$Output)
"@
}

function Write-MockGeminiSkill {
    param(
        [string]$SkillRoot,
        [string]$Marker
    )

    $scriptPath = Join-Path $SkillRoot 'gemini-designer-main\scripts\invoke-gemini.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $scriptPath) -Force | Out-Null
    Write-Utf8Bom -Path $scriptPath -Content @"
[CmdletBinding()]
param(
    [string]`$Workspace,
    [string]`$Prompt,
    [string]`$OutputFormat = 'text',
    [string]`$ApprovalMode = 'plan',
    [string]`$Model
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$record = [ordered]@{
    marker = '$Marker'
    workspace = `$Workspace
    prompt = `$Prompt
    output_format = `$OutputFormat
    approval_mode = `$ApprovalMode
    model = `$Model
}
`$recordPath = Join-Path `$Workspace 'gemini-call.json'
[System.IO.File]::WriteAllText(`$recordPath, ((`$record | ConvertTo-Json -Depth 5 -Compress)), (New-Object System.Text.UTF8Encoding(`$false)))
[pscustomobject]@{
    ok = `$true
    exit_code = 0
    stdout = 'mock gemini output'
} | ConvertTo-Json -Compress -Depth 5
"@
}

function Write-ToolProfileDescriptor {
    param(
        [string]$ProfilesRoot,
        [string]$Name,
        [string]$Backend,
        [string]$Model,
        [string[]]$SkillDirs
    )

    $profilePath = Join-Path $ProfilesRoot ("{0}.yaml" -f $Name)
    $skillDirLines = @($SkillDirs | ForEach-Object { "  - {0}" -f $_ })
    $contentLines = @(
        "name: $Name",
        "backend: $Backend",
        "model: $Model",
        'skills_dirs:'
    ) + $skillDirLines + @(
        'enabled_skills:',
        '  - gemini-designer-main',
        'disabled_builtin_skills: []',
        'context: |',
        '  Test-only profile descriptor for skill resolution coverage.'
    )

    Write-Utf8NoBom -Path $profilePath -Content ($contentLines -join "`r`n")
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $RepoRoot
$adapterPath = Join-Path $fixtureRoot 'scripts\invoke-harness-skill.ps1'
$validatorPath = Join-Path $fixtureRoot 'scripts\validate-lite-artifacts.ps1'
$skillsIndexPath = Join-Path $fixtureRoot 'scripts\generate-skills-index.ps1'
$taskBase = Join-Path $fixtureRoot 'docs\tasks'
$script:Checks = @()
$script:Failures = @()
$cleanupPaths = @($fixtureRoot)
$originalUserProfile = $env:USERPROFILE

try {
    $taskA1 = 'skill-contract-a1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskA1Dir = Join-Path $taskBase $taskA1
    New-Item -ItemType Directory -Path $taskA1Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskA1Dir 'plan.md') -Content (New-PlanContent -TaskId $taskA1 -Stage 'PLAN' -Tool 'claudecode')
    $workspaceA1 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-a1-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceA1
    New-Item -ItemType Directory -Path $workspaceA1 -Force | Out-Null
    $a1Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA1 -Stage 'PLAN' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceA1 -ArtifactRoot $taskA1Dir
    $a1Json = Assert-SingleLineJson -JsonText $a1Result.StdOut -Label 'A1'
    if ($a1Result.ExitCode -eq 0 -and $null -ne $a1Json -and $a1Json.ok -and $a1Json.status -eq 'markdown-fallback' -and $a1Result.StdErr -match 'fall back to Markdown-skill flow') {
        Add-Check 'A1 review stub returns single-line markdown-fallback JSON'
    } else {
        Add-Failure ("A1 review stub contract failed, got stdout=[{0}] stderr=[{1}]" -f $a1Result.StdOut, $a1Result.StdErr)
    }

    $taskA2 = 'skill-contract-a2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskA2Dir = Join-Path $taskBase $taskA2
    New-Item -ItemType Directory -Path $taskA2Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskA2Dir 'plan.md') -Content (New-PlanContent -TaskId $taskA2 -Stage 'IMPLEMENT' -Tool 'claudecode')
    $workspaceA2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-a2-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceA2
    New-Item -ItemType Directory -Path $workspaceA2 -Force | Out-Null
    $a2Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA2 -Stage 'IMPLEMENT' -Skill 'implement' -Tool 'claudecode' -WorkspaceRoot $workspaceA2 -ArtifactRoot $taskA2Dir
    $a2Json = Assert-SingleLineJson -JsonText $a2Result.StdOut -Label 'A2'
    if ($a2Result.ExitCode -ne 0 -and $null -ne $a2Json -and -not $a2Json.ok -and $a2Result.StdErr -match 'adapter refuses side-effect skills') {
        Add-Check 'A2 implement is explicitly rejected by the adapter'
    } else {
        Add-Failure ("A2 implement rejection failed, got stdout=[{0}] stderr=[{1}]" -f $a2Result.StdOut, $a2Result.StdErr)
    }

    $taskA3 = 'skill-contract-a3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskA3Dir = Join-Path $taskBase $taskA3
    New-Item -ItemType Directory -Path $taskA3Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskA3Dir 'plan.md') -Content (New-PlanContent -TaskId $taskA3 -Stage 'PLAN' -Tool 'claudecode')
    $workspaceA3 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-a3-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceA3
    New-Item -ItemType Directory -Path $workspaceA3 -Force | Out-Null
    $a3Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA3 -Stage 'PLAN' -Skill 'nonexistent' -Tool 'codex' -WorkspaceRoot $workspaceA3 -ArtifactRoot $taskA3Dir
    $a3Json = Assert-SingleLineJson -JsonText $a3Result.StdOut -Label 'A3'
    if ($a3Result.ExitCode -ne 0 -and $null -ne $a3Json -and -not $a3Json.ok -and (($a3Json.errors -join ' ') -match 'whitelist')) {
        Add-Check 'A3 whitelist rejects unknown skills'
    } else {
        Add-Failure ("A3 whitelist rejection failed, got stdout=[{0}] stderr=[{1}]" -f $a3Result.StdOut, $a3Result.StdErr)
    }

    $taskA4 = 'skill-contract-a4-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskA4Dir = Join-Path $taskBase $taskA4
    New-Item -ItemType Directory -Path $taskA4Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskA4Dir 'plan.md') -Content (New-PlanContent -TaskId $taskA4 -Stage 'PLAN' -Tool 'claudecode')
    $workspaceA4 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-a4-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceA4
    New-Item -ItemType Directory -Path $workspaceA4 -Force | Out-Null
    $a4Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA4 -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceA4 -ArtifactRoot $taskA4Dir -Mode 'writable'
    $a4Json = Assert-SingleLineJson -JsonText $a4Result.StdOut -Label 'A4'
    if ($a4Result.ExitCode -ne 0 -and $null -ne $a4Json -and -not $a4Json.ok -and $a4Result.StdErr -match 'only supports readonly mode') {
        Add-Check 'A4 codex writable mode is rejected'
    } else {
        Add-Failure ("A4 codex mode rejection failed, got stdout=[{0}] stderr=[{1}]" -f $a4Result.StdOut, $a4Result.StdErr)
    }

    $taskB1 = 'skill-contract-b1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskB1Dir = Join-Path $taskBase $taskB1
    New-Item -ItemType Directory -Path $taskB1Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskB1Dir 'plan.md') -Content (New-PlanContent -TaskId $taskB1 -Stage 'PLAN' -Tool 'claudecode')
    $workspaceB1 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-b1-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceB1
    New-Item -ItemType Directory -Path $workspaceB1 -Force | Out-Null
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceB1 '.assistant\skills') -Marker 'project'
    $payloadB1 = '{"task":"Review repo fixture","file":["docs/tasks/example/plan.md"],"session":"resume-123","model":"gpt-5.5/xhigh","reasoning":"high"}'
    $b1Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskB1 -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceB1 -ArtifactRoot $taskB1Dir -PayloadJson $payloadB1
    $b1Json = Assert-SingleLineJson -JsonText $b1Result.StdOut -Label 'B1'
    $b1Record = Read-FileUtf8 -Path (Join-Path $taskB1Dir 'codex-call.json')
    if ($b1Result.ExitCode -eq 0 -and
        $null -ne $b1Json -and
        $b1Json.ok -and
        $b1Json.status -eq 'delegated' -and
        ($b1Json.handoff -eq 'session_id=mock-session') -and
        $b1Json.artifact_paths.Count -eq 1 -and
        (Test-Path -LiteralPath $b1Json.artifact_paths[0] -PathType Leaf) -and
        $b1Record -match '"marker":"project"' -and
        $b1Record -match '"reasoning":"high"' -and
        $b1Record -match '"model":"gpt-5\.5/xhigh"') {
        Add-Check 'B1 codex adapter delegates readonly calls and preserves payload passthrough'
    } else {
        Add-Failure ("B1 codex delegation failed, got stdout=[{0}] stderr=[{1}] record=[{2}]" -f $b1Result.StdOut, $b1Result.StdErr, $b1Record)
    }

    $taskB2 = 'skill-contract-b2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskB2Dir = Join-Path $taskBase $taskB2
    New-Item -ItemType Directory -Path $taskB2Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskB2Dir 'plan.md') -Content (New-PlanContent -TaskId $taskB2 -Stage 'TEST' -Tool 'gemini')
    $workspaceB2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-b2-' + [guid]::NewGuid().ToString('N'))
    $userProfileB2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-user-b2-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += @($workspaceB2, $userProfileB2)
    New-Item -ItemType Directory -Path $workspaceB2 -Force | Out-Null
    New-Item -ItemType Directory -Path $userProfileB2 -Force | Out-Null
    $b2ProfileId = 'harness-test-gemini-profile-aware'
    $b2RelativeSkillsDir = 'custom-hosts/gemini-profile-aware-skills'
    Write-ToolProfileDescriptor -ProfilesRoot (Join-Path $fixtureRoot 'agent-configs\profiles') -Name $b2ProfileId -Backend 'gemini' -Model 'gemini-2.5-pro' -SkillDirs @($b2RelativeSkillsDir)
    Write-MockGeminiSkill -SkillRoot (Join-Path $userProfileB2 ($b2RelativeSkillsDir -replace '/', '\')) -Marker 'profile-aware-user'
    $env:USERPROFILE = $userProfileB2
    $payloadB2 = '{"prompt":"Summarize the current test evidence","model":"gemini-2.5-pro"}'
    $b2Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskB2 -Stage 'TEST' -Skill 'gemini-designer-main' -Tool 'gemini' -ToolProfileId $b2ProfileId -WorkspaceRoot $workspaceB2 -ArtifactRoot $taskB2Dir -PayloadJson $payloadB2
    $b2Json = Assert-SingleLineJson -JsonText $b2Result.StdOut -Label 'B2'
    $b2Record = Read-FileUtf8 -Path (Join-Path $workspaceB2 'gemini-call.json')
    if ($b2Result.ExitCode -eq 0 -and
        $null -ne $b2Json -and
        $b2Json.ok -and
        $b2Json.status -eq 'delegated' -and
        ($b2Json.handoff -eq 'mock gemini output') -and
        $b2Record -match '"marker":"profile-aware-user"' -and
        $b2Record -match '"approval_mode":"plan"' -and
        $b2Record -match '"output_format":"json"') {
        Add-Check 'B2 gemini adapter resolves ToolProfileId-specific user-level skills outside backend default roots'
    } else {
        Add-Failure ("B2 gemini delegation failed, got stdout=[{0}] stderr=[{1}] record=[{2}]" -f $b2Result.StdOut, $b2Result.StdErr, $b2Record)
    }

    $taskB3 = 'skill-contract-b3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskB3Dir = Join-Path $taskBase $taskB3
    New-Item -ItemType Directory -Path $taskB3Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskB3Dir 'plan.md') -Content (New-PlanContent -TaskId $taskB3 -Stage 'TEST' -Tool 'gemini')
    $workspaceB3 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-b3-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceB3
    New-Item -ItemType Directory -Path $workspaceB3 -Force | Out-Null
    $env:USERPROFILE = $userProfileB2
    $b3Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskB3 -Stage 'TEST' -Skill 'gemini-designer-main' -Tool 'gemini' -WorkspaceRoot $workspaceB3 -ArtifactRoot $taskB3Dir -PayloadJson $payloadB2
    $b3Json = Assert-SingleLineJson -JsonText $b3Result.StdOut -Label 'B3'
    $b3Record = Read-FileUtf8 -Path (Join-Path $workspaceB3 'gemini-call.json')
    if ($b3Result.ExitCode -ne 0 -and
        $null -ne $b3Json -and
        -not $b3Json.ok -and
        [string]::IsNullOrWhiteSpace($b3Record) -and
        $b3Result.StdErr -match '\.gemini\\skills\\gemini-designer-main\\scripts\\invoke-gemini\.ps1') {
        Add-Check 'B3 gemini backend fallback still fails without ToolProfileId when only profile-specific skills_dirs contains the adapter'
    } else {
        Add-Failure ("B3 gemini backend fallback lock failed, got stdout=[{0}] stderr=[{1}] record=[{2}]" -f $b3Result.StdOut, $b3Result.StdErr, $b3Record)
    }

    $taskC1 = 'skill-contract-c1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskC1Dir = Join-Path $taskBase $taskC1
    New-Item -ItemType Directory -Path $taskC1Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskC1Dir 'plan.md') -Content (New-PlanContent -TaskId $taskC1 -Stage 'PLAN' -Tool 'claudecode' -ExtraFrontmatter @('skills_dir: custom/ignored'))
    $workspaceC1 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-c1-' + [guid]::NewGuid().ToString('N'))
    $userProfileC1 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-user-c1-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += @($workspaceC1, $userProfileC1)
    New-Item -ItemType Directory -Path $workspaceC1 -Force | Out-Null
    New-Item -ItemType Directory -Path $userProfileC1 -Force | Out-Null
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceC1 '.assistant\skills') -Marker 'project'
    Write-MockCodexSkill -SkillRoot (Join-Path $userProfileC1 '.codex\skills') -Marker 'user'
    $env:USERPROFILE = $userProfileC1
    $payloadC1 = '{"task":"Prefer project-level skill root"}'
    $c1Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskC1 -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceC1 -ArtifactRoot $taskC1Dir -PayloadJson $payloadC1
    $c1Json = Assert-SingleLineJson -JsonText $c1Result.StdOut -Label 'C1'
    $c1Record = Read-FileUtf8 -Path (Join-Path $taskC1Dir 'codex-call.json')
    if ($c1Result.ExitCode -eq 0 -and
        $null -ne $c1Json -and
        $c1Json.ok -and
        $c1Record -match '"marker":"project"' -and
        $c1Result.StdErr -match 'task-level skills_dir is reserved in Phase 3 and ignored') {
        Add-Check 'C1 project-level skills override user-level and task-level skills_dir stays reserved'
    } else {
        Add-Failure ("C1 skill scope resolution failed, got stdout=[{0}] stderr=[{1}] record=[{2}]" -f $c1Result.StdOut, $c1Result.StdErr, $c1Record)
    }

    $taskC2 = 'skill-contract-c2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskC2Dir = Join-Path $taskBase $taskC2
    New-Item -ItemType Directory -Path $taskC2Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskC2Dir 'plan.md') -Content (New-PlanContent -TaskId $taskC2 -Stage 'PLAN' -Tool 'codex')
    $workspaceC2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-c2-' + [guid]::NewGuid().ToString('N'))
    $userProfileC2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-user-c2-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += @($workspaceC2, $userProfileC2)
    New-Item -ItemType Directory -Path $workspaceC2 -Force | Out-Null
    New-Item -ItemType Directory -Path $userProfileC2 -Force | Out-Null
    Write-MockCodexSkill -SkillRoot (Join-Path $userProfileC2 '.codex\skills') -Marker 'user'
    $env:USERPROFILE = $userProfileC2
    $payloadC2 = '{"task":"Use backend-aware codex user-level skill root"}'
    $c2Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskC2 -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceC2 -ArtifactRoot $taskC2Dir -PayloadJson $payloadC2
    $c2Json = Assert-SingleLineJson -JsonText $c2Result.StdOut -Label 'C2'
    $c2Record = Read-FileUtf8 -Path (Join-Path $taskC2Dir 'codex-call.json')
    if ($c2Result.ExitCode -eq 0 -and
        $null -ne $c2Json -and
        $c2Json.ok -and
        $c2Record -match '"marker":"user"' -and
        $c2Record -match '"task":"Use backend-aware codex user-level skill root"') {
        Add-Check 'C2 codex adapter resolves backend-aware user-level skills without project-level overrides'
    } else {
        Add-Failure ("C2 backend-aware codex fallback failed, got stdout=[{0}] stderr=[{1}] record=[{2}]" -f $c2Result.StdOut, $c2Result.StdErr, $c2Record)
    }

    $taskD1 = 'skill-contract-d1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskD1Dir = Join-Path $taskBase $taskD1
    New-Item -ItemType Directory -Path $taskD1Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskD1Dir 'plan.md') -Content (New-PlanContent -TaskId $taskD1 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun)
    $workspaceD1 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-d1-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceD1
    New-Item -ItemType Directory -Path $workspaceD1 -Force | Out-Null
    $d1Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskD1 -Stage 'PLAN_REVIEW' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceD1 -ArtifactRoot $taskD1Dir
    $d1Json = Assert-SingleLineJson -JsonText $d1Result.StdOut -Label 'D1'
    $d1Plan = Read-FileUtf8 -Path (Join-Path $taskD1Dir 'plan.md')
    $d1Validator = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskD1 -RepoRoot $fixtureRoot
    if ($d1Result.ExitCode -eq 0 -and
        $null -ne $d1Json -and
        $d1Json.ok -and
        $d1Plan -match '(?ms)^## Plan Review\r?\n### Run 1 .*?\r?\n- verdict: pass\r?\n- findings: none\r?\n- next: none\r?\n- invocation: skill=review mode=adapter tool=codex ok=True' -and
        $d1Validator.ExitCode -eq 0) {
        Add-Check 'D1 invocation trace appends only inside an existing Run block and keeps validator green'
    } else {
        Add-Failure ("D1 invocation trace append failed, got stdout=[{0}] stderr=[{1}] validator=[{2}]" -f $d1Result.StdOut, $d1Result.StdErr, $d1Validator.Text)
    }

    $taskD2 = 'skill-contract-d2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskD2Dir = Join-Path $taskBase $taskD2
    New-Item -ItemType Directory -Path $taskD2Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskD2Dir 'plan.md') -Content (New-PlanContent -TaskId $taskD2 -Stage 'PLAN_REVIEW' -Tool 'codex')
    $workspaceD2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-d2-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $workspaceD2
    New-Item -ItemType Directory -Path $workspaceD2 -Force | Out-Null
    $planBeforeHash = (Get-FileHash -LiteralPath (Join-Path $taskD2Dir 'plan.md') -Algorithm SHA256).Hash
    $d2Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskD2 -Stage 'PLAN_REVIEW' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceD2 -ArtifactRoot $taskD2Dir
    $d2Json = Assert-SingleLineJson -JsonText $d2Result.StdOut -Label 'D2'
    $planAfterHash = (Get-FileHash -LiteralPath (Join-Path $taskD2Dir 'plan.md') -Algorithm SHA256).Hash
    $d2Validator = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskD2 -RepoRoot $fixtureRoot
    if ($d2Result.ExitCode -eq 0 -and
        $null -ne $d2Json -and
        $d2Json.ok -and
        $planBeforeHash -eq $planAfterHash -and
        $d2Result.StdErr -match 'invocation trace skipped: no run block' -and
        $d2Validator.ExitCode -eq 0) {
        Add-Check 'D2 invocation trace skips safely when the target section has no Run block'
    } else {
        Add-Failure ("D2 invocation trace skip failed, got stdout=[{0}] stderr=[{1}] validator=[{2}]" -f $d2Result.StdOut, $d2Result.StdErr, $d2Validator.Text)
    }

    $taskE1 = 'skill-contract-e1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskE1Dir = Join-Path $taskBase $taskE1
    New-Item -ItemType Directory -Path $taskE1Dir -Force | Out-Null
    $e1Result = Invoke-GenerateSkillsIndex -ScriptPath $skillsIndexPath -TaskId $taskE1 -Stage 'TEST' -BackendHint 'kimi' -RepoRoot $fixtureRoot
    $skillsIndexDoc = Read-FileUtf8 -Path (Join-Path $taskE1Dir 'skills-index.md')
    if ($e1Result.ExitCode -eq 0 -and
        $skillsIndexDoc -match '^<!-- generated at ' -and
        $skillsIndexDoc -match '# Skills available at TEST \(backend hint: kimi\)' -and
        $skillsIndexDoc -match '\*\*test\*\*' -and
        $skillsIndexDoc -match '\*\*gemini-designer-main\*\*') {
        Add-Check 'E1 generate-skills-index emits workflow-backed markdown with skill descriptions'
    } else {
        Add-Failure ("E1 generate-skills-index failed, got output=[{0}] doc=[{1}]" -f $e1Result.Text, $skillsIndexDoc)
    }
} finally {
    $env:USERPROFILE = $originalUserProfile
    foreach ($path in $cleanupPaths) {
        Remove-DirectoryWithRetry -Path $path
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
