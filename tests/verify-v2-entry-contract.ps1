[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()

function Add-Check {
    param([string]$Message)
    $script:checks.Add($Message)
}

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Success,
        [string]$Failure
    )

    if ($Condition) {
        Add-Check $Success
    } else {
        Add-Failure $Failure
    }
}

function Get-FileDigest {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-GitCapture {
    param([string[]]$Arguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Git baseline process did not start' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Get-TextLineCount {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $normalized = $Text -replace "`r`n?", "`n"
    $count = [regex]::Matches($normalized,"`n").Count
    if (-not $normalized.EndsWith("`n",[System.StringComparison]::Ordinal)) { $count++ }
    return $count
}

function Test-MinimumEntryReduction {
    param(
        [int]$CurrentBytes,
        [int]$BaselineBytes,
        [int]$CurrentLines,
        [int]$BaselineLines
    )

    return ($CurrentBytes * 4) -le ($BaselineBytes * 3) -and ($CurrentLines * 4) -le ($BaselineLines * 3)
}

function Test-ExplicitNewV2FastPath {
    param([AllowEmptyString()][string]$Text)
    $first = $Text.IndexOf('- New identity/artifact-free:',[StringComparison]::Ordinal)
    $known = $Text.IndexOf('- Known identity:',[StringComparison]::Ordinal)
    if ($first -lt 0 -or $known -le $first) { return $false }
    foreach ($fragment in @(
        'host/user-surfaced `HARNESS_PROTOCOL`','else read its process value once','never guess',
        'Resolve admission once','No task `status`, nested shim, or task/runtime/current inspection',
        'No status/runtime/lifecycle fan-out.','valid v2 state wins and may status/resume.',
        'Selected v2 Direct loads no `entry-router`, `orchestrator`, lifecycle skill','hand off now',
        'minimum focused checks covering all confirmed acceptance criteria','Stop only when all required checks pass',
        'An unresolved Requirement or product decision blocks every write and enters Ask',
        'continuation alone enters Ask and authorizes no write','Expand only after failure/ambiguity.'
    )) { if (-not $Text.Contains($fragment,[StringComparison]::Ordinal)) { return $false } }
    return $Text.Contains('Legacy lifecycle and shim loading are retired.',[StringComparison]::Ordinal)
}

function Get-ManagedBlock {
    param([string]$Path)

    $text = (Get-Content -LiteralPath $Path -Raw -Encoding utf8) -replace "`r`n?", "`n"
    $pattern = '(?ms)^<!-- BEGIN GENERATED ENTRY CONTRACT -->\n<!-- source-sha256: (?<digest>[0-9a-f]{64}) -->\n(?<body>.*?)\n<!-- END GENERATED ENTRY CONTRACT -->$'
    $matches = [regex]::Matches($text, $pattern)
    if ($matches.Count -ne 1) {
        return $null
    }

    return [pscustomobject]@{
        Full = $matches[0].Value
        Digest = $matches[0].Groups['digest'].Value
        Body = $matches[0].Groups['body'].Value
        Overlay = $text.Remove($matches[0].Index, $matches[0].Length)
    }
}

function Invoke-GeneratorProcess {
    param(
        [string]$Root,
        [switch]$Check,
        [int]$FailAfterReplace = 0
    )

    $scriptPath = Join-Path $Root 'scripts\generate-entry-contract.ps1'
    $arguments = @('-RepoRoot', $Root)
    if ($Check) {
        $arguments += '-Check'
    }
    $faultVariable = 'DEV_HARNESS_TEST_ENTRY_CONTRACT_FAIL_AFTER_REPLACE'
    $previousFault = [System.Environment]::GetEnvironmentVariable($faultVariable, [System.EnvironmentVariableTarget]::Process)
    try {
        $faultValue = if ($FailAfterReplace -gt 0) { [string]$FailAfterReplace } else { $null }
        [System.Environment]::SetEnvironmentVariable($faultVariable, $faultValue, [System.EnvironmentVariableTarget]::Process)
        $started = Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $scriptPath -Arguments $arguments
    } finally {
        [System.Environment]::SetEnvironmentVariable($faultVariable, $previousFault, [System.EnvironmentVariableTarget]::Process)
    }
    $exited = $started.Process.WaitForExit(30000)
    if (-not $exited) {
        $started.Process.Kill($true)
        [void]$started.Process.WaitForExit(5000)
    }
    $stdout = $started.StdOut.GetAwaiter().GetResult()
    $stderr = $started.StdErr.GetAwaiter().GetResult()
    $exitCode = if ($started.Process.HasExited) { $started.Process.ExitCode } else { -1 }
    $started.Process.Dispose()
    return [pscustomobject]@{
        Exited = $exited
        ExitCode = $exitCode
        Output = (($stdout + $stderr).Trim())
    }
}

$generatorPath = Join-Path $RepoRoot 'scripts\generate-entry-contract.ps1'
$canonicalPath = Join-Path $RepoRoot 'policies\entry-contract.md'
$entryRouterPath = Join-Path $RepoRoot 'skills\entry-router\SKILL.md'
$fixturePath = Join-Path $RepoRoot 'tests\scenarios\entry-contract\v1-routing.json'
$generatedTargetRelativePaths = @(
    'agent-configs/workspace/AGENTS.md.template',
    'agent-configs/claude/CLAUDE.md.template',
    'vault-template/entry/AGENTS.md.template'
)
$entryRelativePaths = @(
    'agent-configs/workspace/AGENTS.md.template',
    'agent-configs/codex/AGENTS.md.template',
    'agent-configs/claude/CLAUDE.md.template',
    'vault-template/entry/AGENTS.md.template'
)
$baselineCommit = 'aee525f6b3b0638f11bf6ab278482aa5b8c79d11'
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-pr02-' + [guid]::NewGuid().ToString('N'))
$statusBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)

try {
    foreach ($scriptPath in @($generatorPath, $PSCommandPath)) {
        Assert-True -Condition (Test-FileHasUtf8Bom -Path $scriptPath) -Success ("{0} has UTF-8 BOM" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} must have UTF-8 BOM" -f (Split-Path -Leaf $scriptPath))
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True -Condition (@($parseErrors).Count -eq 0) -Success ("{0} parses as PowerShell" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} has PowerShell parse errors" -f (Split-Path -Leaf $scriptPath))
    }

    $canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
    $canonicalText = (Get-Content -LiteralPath $canonicalPath -Raw -Encoding utf8) -replace "`r`n?", "`n"
    $canonicalBody = $canonicalText.TrimEnd([char[]]"`n")
    $canonicalDigest = Get-FileDigest -Path $canonicalPath
    $canonicalHasBom = $canonicalBytes.Length -ge 3 -and $canonicalBytes[0] -eq 0xEF -and $canonicalBytes[1] -eq 0xBB -and $canonicalBytes[2] -eq 0xBF
    Assert-True -Condition (-not $canonicalHasBom -and -not $canonicalText.Contains("`r")) -Success 'canonical entry contract is deterministic LF UTF-8 without BOM' -Failure 'canonical entry contract encoding is not deterministic'
    Assert-True -Condition ($canonicalText -match '`protocol_default`:\s*`auto`' -and $canonicalText -match '`auto_resolves_to`:\s*`existing-v2-or-admitted-v2-new-task`' -and $canonicalText -match '`v2_entry_activation`:\s*`v2-only-with-new-work-admission`') -Success 'auto is artifact-first and consumes only a Runtime Default Decision' -Failure 'entry contract protocol detector default is invalid'
    Assert-True -Condition (Test-ExplicitNewV2FastPath -Text $canonicalText) -Success 'new v2 Direct resolves admission once and has a bounded stop condition' -Failure 'entry contract leaves new v2 Direct vulnerable to admission bypass or unbounded discovery'
    foreach ($fragment in @(
            'host/user-surfaced `HARNESS_PROTOCOL`',
            'else read its process value once',
            'never guess',
            'Resolve admission once',
            'No task `status`, nested shim, or task/runtime/current inspection',
            'No status/runtime/lifecycle fan-out.',
            'valid v2 state wins and may status/resume.',
            'minimum focused checks covering all confirmed acceptance criteria',
            'Stop only when all required checks pass'
        )) {
        $mutation = $canonicalText.Replace($fragment, '')
        Assert-True -Condition (-not (Test-ExplicitNewV2FastPath -Text $mutation)) -Success ("fast-path mutation is rejected when removing: {0}" -f $fragment) -Failure ("fast-path verifier survived removal of: {0}" -f $fragment)
    }
    $fastLine = @($canonicalText -split "`n" | Where-Object { $_.StartsWith('- New identity/artifact-free', [System.StringComparison]::Ordinal) })
    $otherwiseLine = @($canonicalText -split "`n" | Where-Object { $_.StartsWith('- Known identity:', [System.StringComparison]::Ordinal) })
    $reorderedMutation = if ($fastLine.Count -eq 1 -and $otherwiseLine.Count -eq 1) {
        $canonicalText.Replace($fastLine[0], '__FAST_PATH__').Replace($otherwiseLine[0], $fastLine[0]).Replace('__FAST_PATH__', $otherwiseLine[0])
    } else { $canonicalText }
    Assert-True -Condition (-not (Test-ExplicitNewV2FastPath -Text $reorderedMutation)) -Success 'fast-path verifier rejects moving Otherwise before explicit new v2' -Failure 'fast-path verifier accepts reordered slow-path precedence'
    Assert-True -Condition ($canonicalText -match 'Legacy lifecycle and shim loading are retired' -and $canonicalText -notmatch '\|\s*`new-readonly`\s*\|' -and $canonicalText -notmatch 'Ask exit criteria|Clarification ledger|resume-current/readonly|inbox-first') -Success 'bootstrap retires legacy routing and preserves explicit Requirement and recovery boundaries' -Failure 'default bootstrap still preloads detailed v1 routing or exposes a retired v1 router'
    Assert-True -Condition ($canonicalText -notmatch '\{(?:REPO_ROOT|VAULT_PATH|CODEX_HOME)\}' -and $canonicalText -notmatch '`auto_resolves_to`:\s*`v2`') -Success 'canonical body is host-neutral and never enables unconditional auto=v2' -Failure 'canonical body contains a host token or unconditional v2 default'

    # Historical v1 routing fixtures remain in the archive boundary, not active Runtime acceptance.

    $realCheck = Invoke-GeneratorProcess -Root $RepoRoot -Check
    Assert-True -Condition ($realCheck.Exited -and $realCheck.ExitCode -eq 0 -and $realCheck.Output -match 'STATUS: PASS') -Success 'generator -Check passes without writing real targets' -Failure ("generator -Check failed: {0}" -f $realCheck.Output)

    $managedBlocks = @()
    $currentBytes = 0
    $currentLines = 0
    $baselineBytes = 0
    $baselineLines = 0
    Assert-True -Condition (-not (Test-MinimumEntryReduction -CurrentBytes 8259 -BaselineBytes 8260 -CurrentLines 83 -BaselineLines 84)) -Success 'one-byte and one-line per-entry reductions cannot satisfy the significant-shrink gate' -Failure 'per-entry gate accepts a negligible reduction'
    Assert-True -Condition (Test-MinimumEntryReduction -CurrentBytes 75 -BaselineBytes 100 -CurrentLines 75 -BaselineLines 100) -Success 'the exact 25-percent per-entry boundary is accepted' -Failure 'per-entry gate rejects its declared boundary'
    foreach ($relativePath in $entryRelativePaths) {
        $path = Join-Path $RepoRoot $relativePath
        $block = Get-ManagedBlock -Path $path
        if ($relativePath -cin $generatedTargetRelativePaths) {
            Assert-True -Condition ($null -ne $block -and $block.Digest -ceq $canonicalDigest -and $block.Body -ceq $canonicalBody) -Success ("{0} contains the canonical generated bootstrap" -f $relativePath) -Failure ("{0} generated bootstrap is missing or stale" -f $relativePath)
        } else {
            Assert-True -Condition ($null -eq $block) -Success ("{0} remains a host-only overlay without a generated contract" -f $relativePath) -Failure ("{0} still duplicates the workspace entry contract" -f $relativePath)
        }
        if ($null -ne $block -and $relativePath -cin $generatedTargetRelativePaths) {
            $managedBlocks += $block.Full
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $lines = @(Get-Content -LiteralPath $path).Count
        $currentBytes += $bytes.Length
        $currentLines += $lines
        Assert-True -Condition ($lines -le 250) -Success ("{0} stays within the 250-line entry budget" -f $relativePath) -Failure ("{0} exceeds the 250-line entry budget" -f $relativePath)

        $sizeResult = Invoke-GitCapture -Arguments @('-C',$RepoRoot,'cat-file','-s',("{0}:{1}" -f $baselineCommit, $relativePath))
        $baseResult = Invoke-GitCapture -Arguments @('-C',$RepoRoot,'show',("{0}:{1}" -f $baselineCommit, $relativePath))
        if ($sizeResult.ExitCode -eq 0 -and $baseResult.ExitCode -eq 0) {
            $baseBytesForPath = [int]$sizeResult.StdOut.Trim()
            $baseLinesForPath = Get-TextLineCount -Text $baseResult.StdOut
            $baselineBytes += $baseBytesForPath
            $baselineLines += $baseLinesForPath
            Assert-True -Condition (Test-MinimumEntryReduction -CurrentBytes $bytes.Length -BaselineBytes $baseBytesForPath -CurrentLines $lines -BaselineLines $baseLinesForPath) -Success ("{0} shrinks by at least 25 percent from its own v1 baseline" -f $relativePath) -Failure ("{0} missed its independent 25 percent reduction gate: {1}/{2} bytes, {3}/{4} lines" -f $relativePath,$bytes.Length,$baseBytesForPath,$lines,$baseLinesForPath)
        } else {
            Add-Failure ("cannot read PR-00 baseline target {0}" -f $relativePath)
        }
    }
    Assert-True -Condition ($managedBlocks.Count -eq 3 -and @($managedBlocks | Select-Object -Unique).Count -eq 1) -Success 'workspace, Claude, and retained historical shim carry one byte-identical managed bootstrap' -Failure 'allowlisted generated bootstraps are not identical'
    $codexOverlay = Get-Content -LiteralPath (Join-Path $RepoRoot 'agent-configs\codex\AGENTS.md.template') -Raw -Encoding utf8
    Assert-True -Condition ($codexOverlay -notmatch 'BEGIN GENERATED ENTRY CONTRACT|`protocol_default`|\|\s*`new-readonly`\s*\|') -Success 'Codex global entry contains only a host overlay' -Failure 'Codex global entry still preloads shared or v1 routing rules'
    $workspaceOverlay = (Get-ManagedBlock -Path (Join-Path $RepoRoot 'agent-configs\workspace\AGENTS.md.template')).Overlay
    Assert-True -Condition ($workspaceOverlay -match 'task\.ps1 status` only for an explicit v2 recovery/status request' -and $workspaceOverlay -match 'Never read an old' -and $workspaceOverlay -notmatch 'Use `\.assistant\\entry\\task\.ps1 status` for a read-only v2 recovery view|The executable workspace entry shim remains') -Success 'workspace overlay keeps status and nested entry lazy outside selected v2 Direct' -Failure 'workspace overlay still invites selected v2 Direct into status or nested entry discovery'
    $claudeOverlay = (Get-ManagedBlock -Path (Join-Path $RepoRoot 'agent-configs\claude\CLAUDE.md.template')).Overlay
    Assert-True -Condition ($claudeOverlay -notmatch '(?m)^- Call `/entry-router` at the start of each conversation\.$') -Success 'Claude overlay has no unconditional entry-router first-hop rule' -Failure 'Claude overlay still forces entry-router before v2 Direct classification'
    Assert-True -Condition ($claudeOverlay -match 'Legacy `/entry-router` is retired') -Success 'Claude overlay retires legacy entry-router' -Failure 'Claude overlay does not preserve the retired entry-router boundary'
    Assert-True -Condition ($baselineBytes -eq 22194 -and $baselineLines -eq 206) -Success 'fixed PR-00 entry baseline is reproducible at 22194 bytes and 206 lines' -Failure ("fixed entry baseline drifted: {0} bytes, {1} lines" -f $baselineBytes,$baselineLines)
    Assert-True -Condition (Test-MinimumEntryReduction -CurrentBytes $currentBytes -BaselineBytes $baselineBytes -CurrentLines $currentLines -BaselineLines $baselineLines) -Success ("default entry surfaces shrink by at least 25 percent to {0} bytes and {1} lines" -f $currentBytes,$currentLines) -Failure ("default entry surfaces missed the 25 percent reduction gate: {0} bytes and {1} lines" -f $currentBytes,$currentLines)

    New-Item -ItemType Directory -Path $scratchRoot | Out-Null
    foreach ($relativePath in @('scripts/generate-entry-contract.ps1', 'scripts/lib/Harness.RuntimeKernel.ps1', 'scripts/lib/Harness.AtomicWrite.psm1', 'scripts/lib/Harness.Hashing.psm1', 'scripts/lib/Harness.Path.psm1', 'policies/entry-contract.md') + $generatedTargetRelativePaths) {
        Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $scratchRoot -RelativePath $relativePath
    }
    $fifthPath = Join-Path $scratchRoot 'agent-configs\unmanaged\AGENTS.md.template'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fifthPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($fifthPath, "unmanaged`n<!-- BEGIN GENERATED ENTRY CONTRACT -->`nkeep`n<!-- END GENERATED ENTRY CONTRACT -->`n", (New-Object System.Text.UTF8Encoding($false)))
    $fifthBefore = Get-FileDigest -Path $fifthPath
    $overlayBefore = @{}
    foreach ($relativePath in $generatedTargetRelativePaths) {
        $overlayBefore[$relativePath] = (Get-ManagedBlock -Path (Join-Path $scratchRoot $relativePath)).Overlay
    }

    $firstApply = Invoke-GeneratorProcess -Root $scratchRoot
    $firstHashes = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $secondApply = Invoke-GeneratorProcess -Root $scratchRoot
    $secondHashes = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    Assert-True -Condition ($firstApply.ExitCode -eq 0 -and $secondApply.ExitCode -eq 0 -and @(Compare-Object $firstHashes $secondHashes -SyncWindow 0).Count -eq 0) -Success 'two generator applications are byte-idempotent' -Failure 'generator application is not idempotent'
    $overlaysPreserved = @($generatedTargetRelativePaths | Where-Object { (Get-ManagedBlock -Path (Join-Path $scratchRoot $_)).Overlay -cne $overlayBefore[$_] }).Count -eq 0
    Assert-True -Condition $overlaysPreserved -Success 'generation preserves every host overlay outside the markers' -Failure 'generation changed a host overlay'

    $tempCanonical = Join-Path $scratchRoot 'policies\entry-contract.md'
    $changedCanonical = ((Get-Content -LiteralPath $tempCanonical -Raw -Encoding utf8) -replace "`r`n?", "`n").TrimEnd([char[]]"`n") + "`n<!-- verifier canonical mutation -->`n"
    [System.IO.File]::WriteAllText($tempCanonical, $changedCanonical, (New-Object System.Text.UTF8Encoding($false)))
    $changedDigest = Get-FileDigest -Path $tempCanonical
    $changedApply = Invoke-GeneratorProcess -Root $scratchRoot
    $allChanged = @($generatedTargetRelativePaths | Where-Object { (Get-ManagedBlock -Path (Join-Path $scratchRoot $_)).Digest -cne $changedDigest }).Count -eq 0
    Assert-True -Condition ($changedApply.ExitCode -eq 0 -and $allChanged) -Success 'one canonical edit updates all three host-appropriate targets in one run' -Failure 'canonical edit did not update every allowlisted target'
    Assert-True -Condition ((Get-FileDigest -Path $fifthPath) -ceq $fifthBefore) -Success 'generator leaves an unmanaged fifth entry file untouched' -Failure 'generator wrote outside its hardcoded allowlist'

    $beforeReservedMarker = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    [System.IO.File]::WriteAllText($tempCanonical, ($changedCanonical.TrimEnd([char[]]"`n") + "`n<!-- BEGIN GENERATED ENTRY CONTRACT -->`n"), (New-Object System.Text.UTF8Encoding($false)))
    $reservedMarkerApply = Invoke-GeneratorProcess -Root $scratchRoot
    $afterReservedMarker = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    Assert-True -Condition ($reservedMarkerApply.ExitCode -ne 0 -and @(Compare-Object $beforeReservedMarker $afterReservedMarker -SyncWindow 0).Count -eq 0) -Success 'canonical source rejects reserved markers before any target write' -Failure 'reserved source marker was accepted or changed a target'
    [System.IO.File]::WriteAllText($tempCanonical, $changedCanonical, (New-Object System.Text.UTF8Encoding($false)))

    $beforeInjectedFailure = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $faultCanonical = $changedCanonical.TrimEnd([char[]]"`n") + "`n<!-- verifier publish fault -->`n"
    [System.IO.File]::WriteAllText($tempCanonical, $faultCanonical, (New-Object System.Text.UTF8Encoding($false)))
    $faultApply = Invoke-GeneratorProcess -Root $scratchRoot -FailAfterReplace 2
    $afterInjectedFailure = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $publishDebris = @(Get-ChildItem -LiteralPath $scratchRoot -Recurse -File | Where-Object { $_.Name -match '\.entry-contract\.(?:tmp|bak|rollback)$' })
    Assert-True -Condition ($faultApply.ExitCode -ne 0 -and $faultApply.Output -match 'rolled back' -and @(Compare-Object $beforeInjectedFailure $afterInjectedFailure -SyncWindow 0).Count -eq 0 -and $publishDebris.Count -eq 0) -Success 'mid-publish fault rolls back every replaced target without debris' -Failure ("mid-publish fault was not transactionally rolled back: {0}" -f $faultApply.Output)
    [System.IO.File]::WriteAllText($tempCanonical, $changedCanonical, (New-Object System.Text.UTF8Encoding($false)))
    $postRollbackCheck = Invoke-GeneratorProcess -Root $scratchRoot -Check
    Assert-True -Condition ($postRollbackCheck.ExitCode -eq 0) -Success 'targets remain current after injected rollback' -Failure 'injected rollback left generated targets inconsistent'

    $driftPath = Join-Path $scratchRoot $generatedTargetRelativePaths[0]
    $driftText = (Get-Content -LiteralPath $driftPath -Raw -Encoding utf8).Replace('# Entry Contract', '# Entry Contract drift')
    [System.IO.File]::WriteAllText($driftPath, $driftText, (New-Object System.Text.UTF8Encoding($false)))
    $driftBefore = Get-FileDigest -Path $driftPath
    $driftCheck = Invoke-GeneratorProcess -Root $scratchRoot -Check
    Assert-True -Condition ($driftCheck.ExitCode -ne 0 -and (Get-FileDigest -Path $driftPath) -ceq $driftBefore) -Success '-Check reports drift nonzero and performs no write' -Failure '-Check accepted drift or changed the target'
    [void](Invoke-GeneratorProcess -Root $scratchRoot)

    $brokenPath = Join-Path $scratchRoot $generatedTargetRelativePaths[0]
    $otherDriftPath = Join-Path $scratchRoot $generatedTargetRelativePaths[1]
    $brokenText = (Get-Content -LiteralPath $brokenPath -Raw -Encoding utf8).Replace('<!-- END GENERATED ENTRY CONTRACT -->', '<!-- BEGIN GENERATED ENTRY CONTRACT -->')
    [System.IO.File]::WriteAllText($brokenPath, $brokenText, (New-Object System.Text.UTF8Encoding($false)))
    $otherDriftText = (Get-Content -LiteralPath $otherDriftPath -Raw -Encoding utf8).Replace('# Entry Contract', '# Entry Contract pending')
    [System.IO.File]::WriteAllText($otherDriftPath, $otherDriftText, (New-Object System.Text.UTF8Encoding($false)))
    $beforeMalformed = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $malformedApply = Invoke-GeneratorProcess -Root $scratchRoot
    $afterMalformed = @($generatedTargetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    Assert-True -Condition ($malformedApply.ExitCode -ne 0 -and @(Compare-Object $beforeMalformed $afterMalformed -SyncWindow 0).Count -eq 0) -Success 'duplicate or malformed markers fail before any target write' -Failure 'malformed marker handling caused a partial write'
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

$statusAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Assert-True -Condition (@(Compare-Object $statusBefore $statusAfter).Count -eq 0) -Success 'entry-contract verification performs no repository or runtime writes' -Failure 'entry-contract verification changed repository state'

foreach ($check in $script:checks) {
    Write-Output ("[PASS] {0}" -f $check)
}
foreach ($failure in $script:failures) {
    Write-Output ("[FAIL] {0}" -f $failure)
}

if ($script:failures.Count -gt 0) {
    Write-Output ("STATUS: FAIL ({0} failed)" -f $script:failures.Count)
    exit 1
}

Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
exit 0
